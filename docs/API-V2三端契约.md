# MyYaris V2 三端系统契约规范 (HTTP / WebSocket)

- **适用系统**：MyYaris V2 全链路系统
- **端侧范围**：
  1. **iOS App** (`ios_app`)：iPhone 手机控制端
  2. **Vehicle App** (`car_app`)：Ottocast P3 Pro 车机播放与导航端
  3. **Backend** (`backend`)：R9000P 边缘中枢服务 (FastAPI / SQLite / Tailscale TLS)
- **文档维护者**：后端团队 (端侧只读引用)
- **基线日期**：2026-10-12 (V2.1 增强版)

---

## 1. 设备标识规范与别名归一化 (Device ID Normalization)

### 1.1 标准规范
车机端的物理型号为 **Ottocast P3 Pro**。在历史版本、配置文件与不同端侧代码中，存在两个设备标识符：
- **规范标准 ID (Canonical)**: `car_p3pro`（系统底层、数据库存储与默认配置的唯一主键）
- **兼容别名 (Alias)**: `ottocast_p3_pro`（历史车机端上报或用户自定义输入的别名）

### 1.2 归一化准则 (Backend Rule)
后端在所有涉及设备鉴权、任务派发、状态持久化、长轮询拉取和 WebSocket 广播前，**必须先执行设备别名归一化**：
```python
KNOWN_CAR_ALIASES = {"car_p3pro", "ottocast_p3_pro"}

def resolve_car_device_id(input_id: Optional[str] = None, fallback_id: Optional[str] = None) -> str:
    candidate = (input_id or fallback_id or "car_p3pro").strip()
    if candidate in KNOWN_CAR_ALIASES:
        return "car_p3pro"
    return candidate
```

### 1.3 权限与隔离 (ACL Checks)
- 车机 Token (`CAR_TOKEN`) 默认绑定设备 `car_p3pro`。
- 车机请求 `/devices/{id}/tasks/next`、`/tasks/{id}/ack`、`/music/control/status`、`/music/control/command/next` 或 `/music/control/command/{id}/ack` 时，后端在比对 `user.device_id` 与目标 `device_id` 前进行别名归一化判断。
- 当且仅当 `is_same_device(user.device_id, target_device_id)` 为 True 时放行，既消除了 `ottocast_p3_pro` 报 403 Forbidden 或 204 No Content 的设备陷阱，又严格保证了跨设备越权的绝对阻断。

---

## 2. 导航生命周期：解析与派发两阶段分离 (Resolve vs Dispatch)

为了解决手机端预览/多候选确认需求与 Siri 快捷指令自动化之间的冲突，系统严格区分两阶段流程与向下兼容通道：

```
[iPhone App / 用户交互]
  POST /api/v1/destinations/resolve ---> 解析经纬度/POI/链接 (纯解析，不创建任务)
                                              |
                                              v (用户在界面确认目标与车辆)
  POST /api/v1/tasks/destination     ---> 正式创建 Task，绑定 target_device_id 并在车机端生效

[Siri Shortcuts / 历史自动化]
  POST /destinations (input_type="auto"|"coords") ---> 自动解析 + 立即自动创建 Task (无需二次点击)
```

### 2.1 纯解析阶段 (Phase 1: Pure Resolution)
- **接口**：`POST /api/v1/destinations/resolve`
- **请求体**：
  ```json
  {
    "raw_input": "MPR3+PP",
    "source": "ios_share",
    "purpose": "favorite_preview",      // 可选: "favorite_preview" (默认) | "navigation"
    "reference_coordinate": {          // 短 Plus Code 必填，且严格要求 WGS84
      "latitude": 35.6812,
      "longitude": 139.7671,
      "coord_system": "wgs84"
    }
  }
  ```
- **行为约束与契约保障**：
  - **支持类型与输入校验**：
    - 解析经纬度文本、主流地图分享短链、Plus Code（全码离线解码 / 短码必须提供显式 WGS84 参考坐标离线恢复）或在线 POI。
    - **非空与空白防御**：`raw_input` 严禁为空字符串或纯空白字符；传入空白内容时服务端直接返回 `HTTP 422 Unprocessable Entity`（`detail: "输入内容不能为空。"`），断言不产生任何 `ParseRequest` 或 `Task` 数据库副作用。
  - **Open Location Code 区域中心声明**：Open Location Code (Plus Code) 表示的是地球表面分级网格区域，解码出的经纬度为**该网格单元的几何中心坐标 (`latitudeCenter`, `longitudeCenter`)，绝非建筑物大门或出入口的精确图钉坐标**。
  - **短 Plus Code 严格约束与拒绝猜测**：
    - 短码在 `/api/v1/destinations/resolve` 流程中**必须显式提供合法的 WGS84 参考坐标 (`coord_system: "wgs84"`)**；
    - 若未传 `reference_coordinate`（即使文本中附带城市名称），服务端**断然拒绝并返回 `HTTP 422 Unprocessable Entity`**，严禁调用外部地理编码服务猜测，杜绝虚假经纬度 `(0.0, 0.0)` 兜底；
    - 参照坐标非 `wgs84` 或经纬度越界同样返回 `422`。
  - **Purpose 契约与确认状态语义**：
    - `purpose` 字段支持 `"favorite_preview"`（默认值）与 `"navigation"`。
    - 短码经参照坐标还原、全码粗粒度编码（编码长度 < 10）以及产生多个候选的检索结果，服务端固定返回 `needs_confirmation: true` 与 `status: "needs_clarification"` 及澄清提示 `clarification_question`；
    - **统一预览防派发安全保护**：为收藏预览用途（默认 `purpose="favorite_preview"`）创建的解析记录，**统一严禁用于派发车机导航任务**——无论是调用单候选直接派发接口 `POST /api/v1/tasks/destination` 还是多候选确认派发接口 `POST /destinations/{id}/confirm`，服务端均严格拦截并返回 `HTTP 400 Bad Request`，杜绝误触派发；
    - **iOS 真实导航派发流程**：当用户在 iOS 主界面或地图分享直接发起真实车机导航时，客户端必须显式传入 `"purpose": "navigation"`；当解析状态为 `"resolved"` 时，方可通过 `POST /api/v1/tasks/destination` 或 `POST /destinations/{id}/confirm` 正常生成 `Task`。
  - **严禁提前创建任务 (Zero Eager Task)**：解析阶段 `auto_create_task=False` 始终生效，`tasks` 表不产生任何新增记录（`parse_request.task_id = None`）。
  - **多候选完整透传**：多候选时，响应中的 `candidates` 数组返回全量候选列表，客户端不可将首个候选误判为唯一确定地点。
  - **响应结构 (`200 OK`)**：
    ```json
    {
      "code": 200,
      "destination_id": "req_12345678",
      "name": "Plus Code 8Q7XMPR3+PP",
      "latitude": 35.6983,
      "longitude": 139.7730,
      "confidence": 0.85,
      "status": "needs_clarification",
      "message": null,
      "clarification_question": "已按参照位置还原最近匹配的短编码区域中心，请确认是否为目标地点；参照位置偏差可能导致错误地点。",
      "needs_confirmation": true,
      "candidates": [
        {
          "candidate_id": "cand_98765432",
          "title": "Plus Code 8Q7XMPR3+PP",
          "address": "Plus Code 编码区域中心（按参照位置还原，非建筑物入口精确坐标）",
          "latitude": 35.6983,
          "longitude": 139.7730,
          "coord_system": "wgs84",
          "source": "plus_code"
        }
      ]
    }
    ```

### 2.2 正式派发阶段 (Phase 2: Formal Dispatch)
- **单候选/直接派发**：`POST /api/v1/tasks/destination`
  - 请求体：`{"destination_id": "...", "target_device_id": "...", "expires_in_seconds": 3600}`
  - 拦截与门禁：
    - 若该解析记录为收藏预览用途（`purpose="favorite_preview"`），**严格拒绝并返回 `HTTP 400 Bad Request`**；
    - 若该解析记录状态为 `needs_clarification`，**严格拒绝并返回 `HTTP 400 Bad Request`**（要求客户端先二次澄清或确认目标）；
  - 行为：创建状态为 `queued` 的正式 `Task`，将 `target_device_id` 归一化并写入 `Task.device_id`。
- **多候选确认派发**：`POST /destinations/{id}/confirm`
  - 请求体：`{"candidate_id": "...", "target_device_id": "..."}`
  - 拦截与门禁：若目标记录为收藏预览用途（`purpose="favorite_preview"`），**同样严格拒绝并返回 `HTTP 400 Bad Request`**。
  - 行为：将选定的候选点生成任务，并更新请求关联。
- **幂等与设备重指派**：
  - 若该 `request_id` 已存在未领取的初始任务（状态为 `queued` 或 `received`），而用户再次提交了不同的 `target_device_id`，后端自动更新 `existing_task.device_id` 为新目标，避免旧任务滞留或重复创建。

### 2.3 历史兼容接口 (Legacy Auto Mode)
- **接口**：`POST /destinations`
- **请求体**：`DestinationCreateRequest(auto_create_task=True, ...)`
- **行为约束**：保持原有行为，明确坐标或单图钉链接解析成功后，**自动创建 Task**，确保现有 iPhone 快捷指令即点即走。

---

## 3. WebSocket 实时双工与双信封契约 (Dual Envelope & State Sync)

> **V2.2 音乐播放队列与全状态同步契约已冻结**：  
> 包含“车机自主全量喜欢歌单维护（列表循环 `list_loop` / 随机播放 `shuffle`）、真实心动模式 (`intelligence`)、临时搜索点播单曲队列、零自动播放、3 次切歌失败熔断与新旧能力协商”，完整技术规范详见专篇契约：[音乐播放队列与状态同步契约](./音乐播放队列与状态同步契约.md)。

### 3.1 路径与鉴权
- **URL**：`wss://<host>/api/v1/ws/music?client_type=<car|phone>&device_id=<device_id>`
- **鉴权头**：
  - 推荐：`Authorization: Bearer <TOKEN>`（手机或车机专用 Token）
  - 兼容：`X-Device-Token: <TOKEN>` 或 URL Query `?token=<TOKEN>`

### 3.2 报文信封体系 (Standard vs Root Compatibility)
为兼容不同端侧的 JSON 解析逻辑（手机侧期望嵌套 `data` 对象，车机侧期望扁平根字段），后端下发与广播采用**双信封架构 (Dual Envelope)**：

#### (1) 状态快照与广播 (`status_snapshot` / `status_update`)
当车机状态上报或客户端连接时，后端发出的报文结构：
```json
{
  "type": "status_update",
  "timestamp": "2026-10-19T12:00:00Z",
  "device_id": "car_example",
  "playback_state": "playing",
  "applied_mode": "list_loop",
  "requested_mode": "list_loop",
  "queue_id": "q_fav_a1b2c3d4e5f6",
  "queue_version": 102,
  "queue_source": "netease_favorite",
  "current_index": 45,
  "current_track_id": "netease_1901371647",
  "position_ms": 45000,
  "duration_ms": 240000,
  "software_volume": 0.25,
  "capabilities": ["queue_v2", "intelligence_v1", "full_favorite_shuffle"],
  "data": {
    "device_id": "car_example",
    "playback_state": "playing",
    "applied_mode": "list_loop",
    "requested_mode": "list_loop",
    "queue_id": "q_fav_a1b2c3d4e5f6",
    "queue_version": 102,
    "queue_source": "netease_favorite",
    "current_index": 45,
    "current_track_id": "netease_1901371647",
    "position_ms": 45000,
    "duration_ms": 240000,
    "software_volume": 0.25,
    "capabilities": ["queue_v2", "intelligence_v1", "full_favorite_shuffle"],
    "last_heartbeat_at": "2026-10-19T12:00:00Z",
    "updated_at": "2026-10-19T12:00:00Z"
  }
}
```
- **手机端解析**：读取 `msg["data"]`，验证 `data["device_id"]` 匹配当前会话，提取播放状态。
- **车机端解析**：可直接读取顶层字段 `msg["playback_state"]`、`msg["position_ms"]` 等。

#### (2) 音乐播控指令 (`music_command`)
当手机通过 HTTP 或 WebSocket 发送播控时，后端下发给车机 WebSocket 的报文结构：
```json
{
  "type": "music_command",
  "timestamp": "2026-10-12T14:00:01Z",
  "command_id": "cmd_music_abc123",
  "device_id": "car_example",
  "action": "play_track",
  "command": "play_track",
  "params": {
    "track_id": "netease_1901371647",
    "stream_url": "/api/v1/music/netease/stream/1901371647",
    "title": "海阔天空",
    "artist": "Beyond",
    "seek_ms": 0,
    "loop_mode": "all"
  },
  "data": {
    "command_id": "cmd_music_abc123",
    "device_id": "car_example",
    "action": "play_track",
    "params": { ... }
  }
}
```
- **车机端解析**：`car_music_sync_service.dart` 可直接提取顶层 `msg["action"]` 与 `msg["params"]`，无缝执行。

### 3.3 车机状态上报校验与防清空保护 (Payload Validation)
车机通过 WebSocket 发送 `{"type": "status_update", ...}` 时：
- 支持车机发送扁平结构（字段在根节点）或信封结构（字段在 `data` 节点）。
- **保护策略**：后端严密校验是否存在有效播放状态字段（`playback_state`、`current_track_id`、`position_ms` 等）。
- **严禁覆盖为空**：若收到的 payload 为空字典 `{}` 或缺少核心字段，后端丢弃该异常报文或从现有数据库快照继承未变动的字段，**坚决不将有效播放状态覆盖为 stopped / 0**。

---

## 4. 播控命令全生命周期与车机执行确认契约 (Command Lifecycle & Acknowledgement)

### 4.1 核心问题与设计原则
1. **WS 发送成功 != 车机执行成功**：调用底层 TCP `ws.send_json` 成功仅代表数据已推入内核发送缓冲区，可能车机随后断网、Flutter 解析异常或播放器报错；绝不能用“发送成功”冒充“已消费/已执行”。
2. **两阶段回执区分**：
   - **服务端接入回执**：手机发起指令时，后端返回 `status: "dispatched"`（或 `"ok"`），表明服务端已入库并调度；
   - **车机端执行回执**：车机真正完成操作后，回报 `received`、`applied`（或 `executed`）或 `failed`。
3. **架构客观定性**：系统采用 **SQLite 持久化 + 单进程异步调度 + 至少一次投递 (At-Least-Once Delivery) + 幂等消费者 (Idempotent Consumer)**，不虚假声称不可达的分布式“Exactly-Once”。

### 4.2 状态机定义 (Command Lifecycle State Machine)
```
       [Phone 发起指令]
              │
              ▼
           queued (后端入库，等待派发)
              │
      ┌───────┴───────┐
      ▼ (WS推达)       ▼ (HTTP拉取)
     sent            sent
      │               │
      ├───────────────┼───────────────┐
      ▼               ▼               ▼
   received        applied          failed (含 error_code / error_detail)
      │               ▲
      └───────────────┘ (最终执行完毕)

      *超时未处理: expires_at 到期后自动标记为 expired
```

| 状态 | 角色与时机 | 说明 |
| :--- | :--- | :--- |
| `queued` | 后端刚接收 | 已入库持久化，进入调度队列 |
| `sent` | 后端完成投递 | 已通过 WebSocket 发出或已由车机 HTTP 长轮询取出 |
| `received` | 车机确认收到 | 车机端已解析报文并排队交给音频引擎 |
| `applied` / `executed` | 车机执行成功 | 音频服务真正完成播放/暂停/Seek/音量切换 |
| `failed` | 车机执行失败 | 解码失败、网络超时或非法音频源，携带错误详情 |
| `expired` | 后端判定超时 | 指令在有效期内未被执行，不再向车机重放 |

### 4.3 幂等性与冲突校验 (Idempotency & Conflict Rules)
所有指令必须具备唯一的 `command_id`（由客户端传入或服务端派发）：
1. **HTTP/WS 双入口交叉幂等**：
   - 无论指令首发来自 HTTP 还是 WebSocket，均由 SQLite 主键（`UNIQUE(command_id)`）和并发隔离事务保障唯一性。
   - **WebSocket 入口重复提交**：若收到相同 `command_id` 且 payload 一致，WS 仅向手机返回 `{type: "command_ack", command_id: "...", status: "<status>", duplicate: true}`，**绝不向车机二次下发、绝不重复入队**。
   - **HTTP 入口重复提交**：若收到相同 `command_id` 且 payload 一致，返回 HTTP 200 OK 既有记录，不重新入库、不重复执行，消除手机弱网重发抖动。
2. **载荷冲突拦截 (Payload Conflict)**：
   - 若相同 `command_id` 携带了不同的 `action` 或不同的 `params`：
   - HTTP 入口返回 **HTTP 409 Conflict**；
   - WebSocket 入口向手机返回 `{type: "command_ack", status: "conflict", error: "Command ID already exists with different action or parameters."}`。
3. **跨设备防撞库与防越权 (Cross-Device Collision)**：
   - 若相同 `command_id` 尝试派发给不同的设备：
   - 后端立即拒绝并返回 **HTTP 409 Conflict**：`Command ID already exists for another device`。
4. **车机回执隔离与终态防回退**：
   - 车机只能确认目标为自身 `device_id` 的指令；跨设备回执一律返回 **HTTP 403 Forbidden**。
   - **终态保护 (Terminal State Protection)**：`applied` 与 `failed` 为终态。一旦记录进入终态，不可被后续的 `received`、`failed` 或 `applied` 篡改或状态回退，重复 ACK 幂等安全。
   - **`received` 非执行终态**：`received` 仅代表车机已接收报文，绝不能视作执行完成，不触发完成移除。
5. **并发去重责任边界**：
   - 服务端实施至少一次投递（At-least-once），不在发送时过早剔除备用队列；
   - 车机端负责基于 `command_id` 进行幂等去重（若通过 WS 与 HTTP 双通道均收到同一 `command_id`，车机只执行一次并上报 `applied` 执行回执）。

### 4.4 有效期与过期防重放 (TTL & Stale Command Suppression)
为防止车辆长达数分钟进出地库或断网重连后，突发重放过期的 Seek、音量或切歌指令：
- **瞬态指令短 TTL**：`seek`、`set_volume` 默认有效期 **20 秒**；
- **普通指令标准 TTL**：`play_track`、`pause`、`resume` 等默认有效期 **60 秒**（客户端可通过 `expires_in_seconds` 显式设置 5~300 秒）；
- **过期即丢弃**：HTTP 长轮询与 WS 派发前均检查 `expires_at`；一旦过期，指令就地标记为 `expired`，绝不下发给车机。

### 4.5 断线恢复与服务端进程重启恢复 (Recovery & Restart Resilience)
- **双通道容灾**：指令经由 WebSocket 发出后，**不会从 HTTP 备用队列中抹除**，保留在调度管理器中；
- 若车机在 WebSocket 保持连接且 3 秒内未回执，或者 WebSocket 发生断开：
  - 车机降级触发 `GET /api/v1/music/control/command/next` 时，该待确认指令将被安全取出并交付车机；
- **进程重启/实例重建恢复 (Process Restart Recovery)**：
  - 服务端重启或 `MusicCommandQueueManager` 实例重建时，从 SQLite 恢复未确认（`queued`/`sent`/`received`）且未过期的待派发指令，同时预载最近的已终态指令 ID 防止重放；
  - 重启后车机发起的 HTTP 轮询能够无缝消费重启前未确认的指令，彻底杜绝单机内存易失导致指令丢失。

---

## 5. 新增车机确认接口与报文规范 (Acknowledgement API & Messages)

### 5.1 HTTP 车机回执接口
- **路径**：`POST /api/v1/music/control/command/{command_id}/ack`
- **鉴权**：`Authorization: Bearer <CAR_TOKEN>` 或 `X-Device-Token`
- **请求体** (`MusicCommandAckRequest`)：
  ```json
  {
    "status": "applied",          // received | applied | failed
    "error_code": null,           // 失败时传入，例如 "TRACK_DECODE_ERROR"
    "error_detail": null,         // 失败详情，例如 "Audio track 404 not found"
    "device_timestamp": "2026-10-12T14:00:02Z"
  }
  ```
- **响应体** (`MusicCommandAckResponse`)：
  ```json
  {
    "command_id": "cmd_music_abc123",
    "status": "applied",
    "accepted": true,
    "message": "Command acknowledged as applied"
  }
  ```

### 5.2 HTTP 指令状态查询接口
- **路径**：`GET /api/v1/music/control/command/{command_id}`
- **鉴权**：手机 Token、车机 Token 或 Admin Token
- **响应体** (`MusicCommandDetailResponse`)：
  ```json
  {
    "command_id": "cmd_music_abc123",
    "device_id": "car_example",
    "action": "play_track",
    "params": { "track_id": "netease_1901371647" },
    "status": "applied",
    "sender_role": "phone",
    "dispatched_channel": "ws",
    "delivery_attempts": 1,
    "created_at": "2026-10-12T14:00:00Z",
    "expires_at": "2026-10-12T14:01:00Z",
    "sent_at": "2026-10-12T14:00:00.1Z",
    "acknowledged_at": "2026-10-12T14:00:00.6Z",
    "error_code": null,
    "error_detail": null
  }
  ```

### 5.3 WebSocket 车机执行回执报文
车机连接 `/api/v1/ws/music` 并在执行后上报：
```json
{
  "type": "command_ack",
  "command_id": "cmd_music_abc123",
  "status": "applied",
  "error_code": null,
  "error_detail": null
}
```

### 5.4 WebSocket 手机端执行状态广播
当车机完成确认（无论是通过 WS 还是 HTTP 回执），后端向该车辆的所有在线手机客户端广播：
```json
{
  "type": "command_status",
  "timestamp": "2026-10-12T14:00:02Z",
  "command_id": "cmd_music_abc123",
  "device_id": "car_example",
  "status": "applied",
  "error_code": null,
  "error_detail": null,
  "data": {
    "command_id": "cmd_music_abc123",
    "device_id": "car_example",
    "status": "applied",
    "error_code": null,
    "error_detail": null
  }
}
```

---

## 6. 播控 Action 与全量播放队列协同规范 (V2.2 扩展)

详细规范见专篇契约：[`docs/音乐播放队列与状态同步契约.md`](./音乐播放队列与状态同步契约.md)。核心原则与接口摘要如下：

### 6.1 播控 Action 枚举
| Action | 支持别名 | 关键参数 (`params`) | 说明 |
| :--- | :--- | :--- | :--- |
| `play_track` | `play` | `song_id`, `track_id`, `source` (`netease_favorite` \| `single_track`), `queue_id`, `queue_version`, `queue_index`, `stream_url`, `title`, `artist`, `seek_position_ms` | 播放指定音轨。**显式喜欢歌单成员点播** (`source="netease_favorite"`) 校验指定快照版本 (不符返 409 `QUEUE_VERSION_CONFLICT`)、来源 (不符返 422 `QUEUE_SOURCE_MISMATCH`)、成员归属 (不在返 404 `TRACK_NOT_IN_QUEUE`)、索引匹配 (不符返 422 `QUEUE_INDEX_MISMATCH`) 及 Owner 权限 (非车主返 403 `OWNER_QUEUE_PERMISSION_DENIED`)，校验失败零落库拦截；成功时注册待定快照，不增版本，车机 ACK applied 后提升为活跃队列并切为 `list_loop`；**显式单曲点播** (`source="single_track"`) 准备单曲队列；**缺省兼容点播** (未传 `source`) 若为当前活跃队列成员则保持队列并更新索引，否则准备单曲队列 |
| `set_playback_mode` | - | `mode` (`list_loop` \| `shuffle` \| `intelligence` \| `single_loop`), `seed_song_id`, `expected_queue_id`, `expected_queue_version` | 显式切换播放模式（限 Owner/Admin，需车机 `queue_v2` 能力门禁） |
| `switch_queue` | - | `source` (`netease_favorite` \| `netease_intelligence` \| `single_track`), `start_index`, `start_track_id` | 显式切换播放队列源（限 Owner/Admin，需车机 `queue_v2` 能力门禁） |
| `pause` | - | - | 暂停当前播放 |
| `resume` | - | - | 恢复播放。若无活跃队列且歌单初始化失败，显式返回 409 Conflict，不创建或派发指令 |
| `stop` | - | - | 停止播放并重置进度 |
| `next` | - | - | 下一首（由车机端基于全量元数据独立维持循环） |
| `prev` | `previous` | - | 上一首 |
| `seek` | - | `seek_position_ms` / `seek_ms` / `position_ms` (单位毫秒) | 跳转指定播放进度（参数冲突返回 422 `SEEK_PARAMETER_CONFLICT`，缺失返回 422 `SEEK_PARAMETER_REQUIRED`，负数返回 422 `INVALID_SEEK_POSITION`；短 TTL 20s 保护） |
| `set_loop` | `set_loop_mode` | `loop_mode`: `"all"` \| `"one"` \| `"off"` | 设置循环模式（向后兼容映射） |
| `set_shuffle` | - | `shuffle`: `true` \| `false` | 设置随机播放开关（向后兼容映射） |
| `set_volume` | - | `volume`: `0.0` ~ `1.0` (浮点数) | 设置车机软件播放音量（短 TTL 20s 保护） |

> **播控同构与状态机保证**：
> 1. **HTTP 与 WebSocket 同构**：HTTP POST `/music/control/command` 与 WebSocket `type: command` 共享统一处理函数，100% 同构执行 Owner 权限门禁、Seek 参数校验、能力门禁与幂等性检查；
> 2. **准备态与应用态解耦**：播控指令生成阶段仅向服务端注册准备态快照 (`_pending_queues`)，绝不提前修改车机状态表中的 `queue_id` 与 `queue_version`；仅当车机真正执行完成并上报 `applied` ACK 时才正式提升为 `_active_queues` 并更新车机状态；车机失败/超时抛弃 pending 快照，迟到 ACK 无法覆盖较新队列。

### 6.2 全量播放队列不可变快照分页 (`GET /api/v1/music/queue`)
- **权限与资源隔离**：严格要求 **Owner 或绑定车机**（`require_owner_or_car`）。Admin 或过渡期 Legacy Phone Token 可访问；车机硬件仅限拉取属于自身 `device_id` 的队列快照；普通注册用户（即使具备车机控制权限）**一律返回 HTTP 403 Forbidden**；未鉴权返回 HTTP 401；
- **纯读无副作用**：纯读幂等查询，Query 带 `?source=...` 绝不激活或改变当前播放队列；冷启动无激活队列时返回未激活的不可变只读视图 (`activate=False`)，不污染活跃播放状态；指定 `(queue_id, queue_version)` 优先命中快照/待定缓存，无需拉取外部喜欢歌单；
- **不可变快照版本绑定**：分页必须携带 `(queue_id, queue_version)`；若版本发生变更，服务端返回 `409 Conflict` (`QUEUE_VERSION_CONFLICT`)，车机丢弃脏数据重新从第 0 页拉取；
- **独立单调递增水位表**：`queue_version` 采用独立的 SQLite `queue_version_sequences` 表持久化水位序列号，毫秒精度单调递增，彻底与车机当前状态解耦，重启或缓存清理后依然保持严格递增且不碰撞；
- **单指令原子状态流转**：发送 `play_track` / `set_playback_mode` / `switch_queue` 时服务端注入 `queue_id`/`queue_version` 并更新 `requested_mode`；仅当车机真正上报 `applied` ACK 时，DB 状态中的 `applied_mode`、`queue_id`、`queue_version` 与 `queue_source` 方正式提交；
- **Opaque 脱敏队列 ID**：喜欢歌单 `q_fav_<hash>`，心动队列 `q_intel_<hash>`，单曲队列 `q_single_<hash>`；
- **标准错误码**：`EMPTY_PLAYLIST` (喜欢歌单为0首)、`QUEUE_NOT_READY` (队列尚未就绪)、`INTELLIGENCE_AUTH_INVALID` (上游网易云凭证无效)、`CAPABILITY_NOT_SUPPORTED` (车机未声明 `queue_v2` 能力)、`TRACK_NOT_IN_QUEUE` (点播曲目不在队列中)、`QUEUE_SOURCE_MISMATCH` (队列源不匹配)、`QUEUE_INDEX_MISMATCH` (索引不匹配)、`OWNER_QUEUE_PERMISSION_DENIED` (普通用户越权点播车主队列)。

---

## 7. 端侧工程师实施对齐指引 (Alignment Guide)

1. **车机端 (`car_app`, Flutter 嵌入式实现) 对齐指引**：
   - 在 `car_music_sync_service.dart` 执行完 `handleCommand` 之后，除上报 `sendCurrentStatus()` 外，发送 WS `command_ack`：
     `_webSocket?.add(jsonEncode({'type': 'command_ack', 'command_id': msg['command_id'], 'status': 'applied'}));`
   - 若执行异常，上报 `status: 'failed'` 与对应 `error_code`；
   - 保持车机端纯内存元数据快照，按需拉取相对路径媒体流，严格遵守连续失败熔断上限（3 首）。
2. **手机端 (`ios_app`, Flutter 客户端实现) 对齐指引**：
   - 现有的 `command_ack` 是即时提交成功握手；
   - 可在 `consumeRealtime` 监听 `type == 'command_status'`，根据 `applied` 或 `failed` 刷新 UI 状态与弹窗报错；
   - 手机端只读拉取队列与状态，不依赖任何未经验证的手机后台切歌代理假设，完全由车机音频服务自主维护循环。

---

## 8. 行驶页单层收藏文件夹与分类收藏协同契约 (V2.2 扩展)

详细规范见 [`docs/收藏夹API契约.md`](file:///path/to/user/Desktop/MyYaris/docs/收藏夹API契约.md)。核心接口与可靠性边界摘要如下：

1. **单层文件夹 CRUD (`/api/v1/favorite-folders`，兼容别名 `/api/v1/favorites/folders`)**：
   - `GET /api/v1/favorite-folders`：分页返回当前登录账号的文件夹列表（含每个文件夹的 `favorite_count`、分页 `has_more` 及未分类总数 `uncategorized_count`），采用 `ORDER BY <sort_by> ASC/DESC, id ASC/DESC` 二级稳定排序；
   - `POST /api/v1/favorite-folders`：创建文件夹（`name` 去空白后 1~64 字符；同账号作用域内通过 SQLite 唯一索引 `uq_favorite_folders_scope_name_norm (owner_scope, name_norm)` 及 `IntegrityError -> 409 Conflict` 事务回滚映射保障并发重名拦截）；
   - `PATCH / PUT /api/v1/favorite-folders/{folder_id}`：重命名文件夹（含并发重名 `409 Conflict` 保护）；
   - `DELETE /api/v1/favorite-folders/{folder_id}`：**同一数据库事务内将其下地址的 `folder_id` 置为 `NULL`（回到未分类）后删除文件夹**，严禁级联删除用户地址，返回 `moved_to_uncategorized_count`。
2. **收藏地址归类与筛选 (`/api/v1/favorites`)**：
   - `GET /api/v1/favorites`：支持 `folder_id=<fld_id>`（按文件夹筛选，不存在或越权返回 `404`）、`uncategorized=true` 或 `folder_id=uncategorized`（筛选未分类 `folder_id IS NULL`）、省略参数（返回当前账号全部地址）；同时传 `uncategorized=true` 与具体 `folder_id=fld_xxx` 返回 `422`；采用 `<sort_by> + id` 二级稳定排序；
   - `POST /api/v1/favorites`：支持可选 `folder_id`；**本接口无 `idempotency_key`，客户端超时严禁盲目自动重试**（防重复创建）；
   - `PATCH / PUT /api/v1/favorites/{favorite_id}`：未传 `folder_id` 时保持原归属不变；传 `"folder_id": "fld_xxx"` 移动到目标文件夹；传 `"folder_id": null` 或 `""` 移回未分类；
   - **重复 `DELETE` 处理**：重复删除同一文件夹或地址返回 `404 Not Found`，客户端收到 `404` 时应视为已删除并刷新列表；
   - **新旧表约束说明**：新库建表 `favorites.folder_id` 含 `REFERENCES favorite_folders(id) ON DELETE SET NULL`；既有生产库通过 `ALTER TABLE favorites ADD COLUMN folder_id VARCHAR(64)` 迁移，不带底层 `REFERENCES` 外键约束，由应用层单事务 `UPDATE + DELETE`、写入归属校验与读取孤儿自愈提供等价保证。


