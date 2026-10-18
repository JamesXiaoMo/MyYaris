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
- **请求体**：`{"raw_input": "...", "source": "ios_share"}`
- **行为约束**：
  - 仅负责解析经纬度、地图链接（支持 Google Maps、Apple Maps、高德等）、Plus Code 或 POI。
  - **严禁提前创建任务**（`parse_request.task_id = None`）。
  - 返回统一的 `destination_id` 以及解析出的地名、经纬度与置信度。

### 2.2 正式派发阶段 (Phase 2: Formal Dispatch)
- **单候选/直接派发**：`POST /api/v1/tasks/destination`
  - 请求体：`{"destination_id": "...", "target_device_id": "...", "expires_in_seconds": 3600}`
  - 行为：创建状态为 `queued` 的正式 `Task`，将 `target_device_id` 归一化并写入 `Task.device_id`。
- **多候选确认派发**：`POST /destinations/{id}/confirm`
  - 请求体：`{"candidate_id": "...", "target_device_id": "..."}`
  - 行为：将选定的候选点生成任务，并更新请求关联。
- **幂等与设备重指派**：
  - 若该 `request_id` 已存在未领取的初始任务（状态为 `queued` 或 `received`），而用户再次提交了不同的 `target_device_id`，后端自动更新 `existing_task.device_id` 为新目标，避免旧任务滞留或重复创建。

### 2.3 历史兼容接口 (Legacy Auto Mode)
- **接口**：`POST /destinations`
- **请求体**：`DestinationCreateRequest(auto_create_task=True, ...)`
- **行为约束**：保持原有行为，明确坐标或单图钉链接解析成功后，**自动创建 Task**，确保现有 iPhone 快捷指令即点即走。

---

## 3. WebSocket 实时双工与双信封契约 (Dual Envelope & State Sync)

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
  "timestamp": "2026-10-12T14:00:00Z",
  "device_id": "car_p3pro",
  "playback_state": "playing",
  "current_track_id": "netease_123456",
  "position_ms": 45000,
  "duration_ms": 240000,
  "software_volume": 0.8,
  "loop_mode": "all",
  "shuffle": false,
  "data": {
    "device_id": "car_p3pro",
    "playback_state": "playing",
    "current_track_id": "netease_123456",
    "position_ms": 45000,
    "duration_ms": 240000,
    "software_volume": 0.8,
    "loop_mode": "all",
    "shuffle_enabled": false,
    "last_heartbeat_at": "2026-10-12T14:00:00Z",
    "updated_at": "2026-10-12T14:00:00Z"
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
  "device_id": "car_p3pro",
  "action": "play_track",
  "command": "play_track",
  "params": {
    "track_id": "netease_123456",
    "stream_url": "https://.../api/v1/music/netease/stream/123456",
    "title": "海阔天空",
    "artist": "Beyond",
    "seek_ms": 0,
    "loop_mode": "all"
  },
  "data": {
    "command_id": "cmd_music_abc123",
    "device_id": "car_p3pro",
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
    "device_id": "car_p3pro",
    "action": "play_track",
    "params": { "track_id": "123" },
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
  "device_id": "car_p3pro",
  "status": "applied",
  "error_code": null,
  "error_detail": null,
  "data": {
    "command_id": "cmd_music_abc123",
    "device_id": "car_p3pro",
    "status": "applied",
    "error_code": null,
    "error_detail": null
  }
}
```

---

## 6. 9 大标准播控 Action 与参数字典

| Action | 支持别名 | 关键参数 (`params`) | 说明 |
| :--- | :--- | :--- | :--- |
| `play_track` | `play` | `track_id`, `stream_url`, `title`, `artist`, `seek_ms` / `seek_position_ms`, `loop_mode`, `shuffle` | 播放指定音轨（本地或网易云私网中继） |
| `pause` | - | - | 暂停当前播放 |
| `resume` | - | - | 恢复播放 |
| `stop` | - | - | 停止播放并重置进度 |
| `next` | - | - | 下一首 |
| `prev` | `previous` | - | 上一首 |
| `seek` | - | `seek_ms` / `seek_position_ms` / `position_ms` (单位毫秒) | 跳转指定播放进度（短 TTL 保护） |
| `set_loop` | `set_loop_mode` | `loop_mode`: `"all"` \| `"one"` \| `"off"` | 设置循环模式 |
| `set_shuffle` | - | `shuffle`: `true` \| `false` | 设置随机播放开关 |
| `set_volume` | - | `volume`: `0.0` ~ `1.0` (浮点数) | 设置车机软件播放音量（短 TTL 保护） |

---

## 7. 端侧工程师实施对齐指引 (Alignment Guide)

1. **车机端 (`car_app`) 后续对齐任务**：
   - 在 `car_music_sync_service.dart` 执行完 `handleCommand` 之后，除上报 `sendCurrentStatus()` 外，增加发送 WS `command_ack`：
     `_webSocket?.add(jsonEncode({'type': 'command_ack', 'command_id': msg['command_id'], 'status': 'applied'}));`
   - 若执行异常，上报 `status: 'failed'` 与对应 `error_code`。
2. **手机端 (`ios_app`) 后续对齐任务**：
   - 现有的 `command_ack` 是即时提交成功握手；
   - 可在 `consumeRealtime` 监听 `type == 'command_status'`，根据 `applied` 或 `failed` 刷新 UI 状态与弹窗报错。

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


