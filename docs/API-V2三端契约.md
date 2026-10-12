# MyYaris V2 三端系统契约规范 (HTTP / WebSocket)

- **适用系统**：MyYaris V2 全链路系统
- **端侧范围**：
  1. **iOS App** (`ios_app`)：iPhone 手机控制端
  2. **Vehicle App** (`car_app`)：Ottocast P3 Pro 车机播放与导航端
  3. **Backend** (`backend`)：R9000P 边缘中枢服务 (FastAPI / SQLite / Tailscale TLS)
- **文档维护者**：后端团队 (端侧只读引用)
- **基线日期**：2026-10-12

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
- 车机请求 `/devices/{id}/tasks/next`、`/tasks/{id}/ack`、`/music/control/status` 或 `/music/control/command/next` 时，后端在比对 `user.device_id` 与目标 `device_id` 前进行别名归一化判断。
- 当且仅当 `is_same_device(user.device_id, target_device_id)` 为 True 时放行，既消除了 `ottocast_p3_pro` 报 403 Forbidden 或 204 No Content 的设备陷阱，又严格保证了非本车设备的越权阻断。

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
- **车机端解析**：`car_music_sync_service.dart` 可直接提取顶层 `msg["action"]` 与 `msg["params"]`，无需改动车机即可无缝执行！

### 3.3 车机状态上报校验与防清空保护 (Payload Validation)
车机通过 WebSocket 发送 `{"type": "status_update", ...}` 时：
- 支持车机发送扁平结构（字段在根节点）或信封结构（字段在 `data` 节点）。
- **保护策略**：后端严密校验是否存在有效播放状态字段（`playback_state`、`current_track_id`、`position_ms` 等）。
- **严禁覆盖为空**：若收到的 payload 为空字典 `{}` 或缺少核心字段，后端丢弃该异常报文或从现有数据库快照继承未变动的字段，**坚决不将有效播放状态覆盖为 stopped / 0**。

---

## 4. 播控指令多通道去重 (Command Deduplication)

### 4.1 核心问题
车机具备 WebSocket 实时连接与 HTTP 长轮询 (`/music/control/command/next`) 双通道。当车机网络不稳定或发生切换时，同一指令可能在两通道被重复拉取，导致“跳过两首歌”或“暂停后又播放”的异常。

### 4.2 去重与派发保障机制
1. **指令唯一定识**：所有指令均分配或携带 `command_id`。
2. **WebSocket 优先实时送达**：
   - 指令下发时，后端优先通过活动 WebSocket 尝试直接推送给目标车机。
   - 若 WebSocket 成功送达（`delivered_count > 0`），后端记录该 `command_id` 为已送达状态，**不向 HTTP 长轮询队列重复塞入该指令**。
3. **HTTP 长轮询延迟过滤**：
   - 车机通过 HTTP 长轮询拉取下一条指令时，队列管理器自动跳过已被 WebSocket 成功消费的 `command_id`，防止双通道重复执行。
4. **客户端重试幂等**：
   - 手机端重复提交相同 `command_id` 的指令时，后端直接返回已调度确认（`MusicCommandResponse`），不再重新排队。

---

## 5. 9 大标准播控 Action 与参数字典

| Action | 支持别名 | 关键参数 (`params`) | 说明 |
| :--- | :--- | :--- | :--- |
| `play_track` | `play` | `track_id`, `stream_url`, `title`, `artist`, `seek_ms` / `seek_position_ms`, `loop_mode`, `shuffle` | 播放指定音轨（本地或网易云私网中继） |
| `pause` | - | - | 暂停当前播放 |
| `resume` | - | - | 恢复播放 |
| `stop` | - | - | 停止播放并重置进度 |
| `next` | - | - | 下一首 |
| `prev` | `previous` | - | 上一首 |
| `seek` | - | `seek_ms` / `seek_position_ms` / `position_ms` (单位毫秒) | 跳转指定播放进度 |
| `set_loop` | `set_loop_mode` | `loop_mode`: `"all"` \| `"one"` \| `"off"` | 设置循环模式 |
| `set_shuffle` | - | `shuffle`: `true` \| `false` | 设置随机播放开关 |
| `set_volume` | - | `volume`: `0.0` ~ `1.0` (浮点数) | 设置车机软件播放音量 |

---

## 6. 端侧开发与联调检查清单 (Checklist)

1. [x] **后端设备别名归一化**：已全局应用 `resolve_car_device_id`，车机无论传 `car_p3pro` 还是 `ottocast_p3_pro` 均可正常轮询任务与回执。
2. [x] **两阶段导航分离**：`POST /api/v1/destinations/resolve` 仅做计算不创建任务，`POST /api/v1/tasks/destination` 正式派发。
3. [x] **WS 双信封支持**：状态广播同时具备 `data` 字典与顶层字段，指令下发具备顶层 `action`/`params` 与 `data` 结构。
4. [x] **状态防清空**：空状态报文与无效数据不污染数据库持久化快照。
5. [x] **指令通道去重**：`command_id` 追踪确保 WebSocket 与 HTTP 长轮询不双发。
6. [x] **所有回归测试自动化验证**：89 项基准测试 + 5 项契约专用集成测试全部通过。
