# MyYaris 车机协同后端接口规范文档 (V2.0)

本文档整理了 MyYaris 项目中目前已实现、部署并全部验证通过的所有后端 API 接口，涵盖导航任务流转、本地音乐流媒体、网易云在线代理与边播边存、扫码/Cookie保活，以及车机远程控制与 WebSocket 全双工同步。

---

## 目录
- [一、全局说明与鉴权机制](#一全局说明与鉴权机制)
- [二、系统状态与健康检查](#二系统状态与健康检查)
- [三、智能导航与目的地流转模块](#三智能导航与目的地流转模块)
  - [3.1 标准 V1 导航接口 (推荐)](#31-标准-v1-导航接口-推荐)
  - [3.2 兼容历史导航接口](#32-兼容历史导航接口)
- [四、本地音频库与流媒体服务模块](#四本地音频库与流媒体服务模块)
- [五、网易云在线曲库与边播边存模块](#五网易云在线曲库与边播边存模块)
- [六、网易云账号授权与保活管理模块](#六网易云账号授权与保活管理模块)
- [七、车机远程控制与状态同步模块](#七车机远程控制与状态同步模块)
- [八、全双工 WebSocket 实时通信接口](#八全双工-websocket-实时通信接口)

---

## 一、全局说明与鉴权机制

### 1.1 服务基础路径
- **局域网 / 本机地址**：`http://127.0.0.1:8000` 或 `http://192.0.2.20:8000`
- **Tailscale 外网穿透域名 (HTTPS / WSS)**：`https://myyaris.example.com`

### 1.2 统一鉴权请求头 (OPS-01)
后端支持双通道身份鉴权：
- **手机客户端 (iPhone Shortcuts / App)**：
  - 请求头：`Authorization: Bearer <PHONE_TOKEN>`
- **车机端 (Ottocast P3 Pro / Android App)**：
  - 请求头：`X-Device-Token: <CAR_TOKEN>`
- **WebSocket 连接**：
  - Query 参数：`?token=<TOKEN>` 或建立握手时的上述请求头。

---

## 二、系统状态与健康检查

### 2.1 获取服务健康状态
- **路径**：`GET /health`
- **鉴权**：公开无需鉴权
- **响应示例 (200 OK)**：
```json
{
  "status": "healthy",
  "version": "1.0.0",
  "timestamp": "2026-10-12T12:00:00Z"
}
```

---

## 三、智能导航与目的地流转模块

### 3.1 标准 V1 导航接口 (推荐)

#### 1. 解析目的地坐标
- **路径**：`POST /api/v1/destinations/resolve`
- **鉴权**：手机端或管理员 (`Authorization: Bearer <PHONE_TOKEN>`)
- **请求体**：
```json
{
  "raw_input": "https://maps.app.goo.gl/EXAMPLE", // 或 "34.4245, 132.7083" 或 "秋叶原电车站"
  "source": "ios_share" // 可选: "ios_share" | "car_ui" | "voice"
}
```
- **响应示例 (200 OK)**：
```json
{
  "code": 200,
  "destination_id": "3b196fb4-2f34-4465-ae66-7f0cd3dc2975",
  "name": "秋叶原电车站",
  "latitude": 35.698383,
  "longitude": 139.773072,
  "confidence": 0.98
}
```

#### 2. 依据已解析目的地生成派发任务
- **路径**：`POST /api/v1/tasks/destination`
- **鉴权**：手机端或管理员 (`Authorization: Bearer <PHONE_TOKEN>`)
- **请求体**：
```json
{
  "destination_id": "3b196fb4-2f34-4465-ae66-7f0cd3dc2975",
  "expires_in_seconds": 3600,
  "target_device_id": "car_p3pro" // 可选，默认为 car_p3pro
}
```
- **响应示例 (200 OK)**：
```json
{
  "task_id": "119cf97f-c967-46b7-8adb-2aff7485e8e8",
  "device_id": "car_p3pro",
  "title": "秋叶原电车站",
  "address": "Tokyo, Japan",
  "latitude": 35.698383,
  "longitude": 139.773072,
  "coord_system": "wgs84",
  "status": "queued",
  "created_at": "2026-10-12T12:00:00Z",
  "expires_at": "2026-10-12T13:00:00Z",
  "delivery_attempts": 0,
  "error_message": null
}
```

#### 3. 车机长轮询拉取待执行任务 (NAV-02)
- **路径**：`GET /api/v1/tasks/poll`
- **鉴权**：车机端或管理员 (`X-Device-Token: <CAR_TOKEN>`)
- **Query 参数**：
  - `device_id`: 设备标识（默认 `car_p3pro`）
  - `timeout`: 长轮询挂起超时秒数（1~60 秒，无任务超时返回 204 No Content）
- **响应**：有任务返回任务对象（结构同上），无任务返回 `204 No Content`。

#### 4. 车机上报任务消费回执 (NAV-03)
- **路径**：`POST /api/v1/tasks/{task_id}/ack`
- **鉴权**：车机端或管理员 (`X-Device-Token: <CAR_TOKEN>`)
- **请求体**：
```json
{
  "phase": "launch_requested", // "received" | "launch_requested" | "acknowledged" | "failed"
  "device_timestamp": "2026-10-12T12:00:05Z",
  "error_code": null,
  "error_detail": null
}
```
- **响应示例 (200 OK)**：
```json
{
  "task_id": "119cf97f-c967-46b7-8adb-2aff7485e8e8",
  "status": "launch_requested",
  "accepted": true,
  "message": "Ack recorded, status is now launch_requested"
}
```

---

### 3.2 兼容历史导航接口
- `POST /destinations`：历史多类型输入接口（支持 `input_type`: `auto` / `coords` / `share_link` / `voice`）。
- `GET /destinations/{id}`：查询指定请求的候选地址详情。
- `POST /destinations/{id}/confirm`：人工确认候选并生成任务。
- `GET /devices/{id}/tasks/next`：历史设备任务长轮询端点。
- `GET /tasks/{id}`：获取单个任务详情。
- `POST /tasks/{id}/ack`：历史任务 ACK 端点。
- `POST /voice`：车机短语音上传与 Whisper 转写端点。

---

## 四、本地音频库与流媒体服务模块

### 4.1 触发本地磁盘扫描与 ID3 索引 (MED-01)
- **路径**：`POST /api/v1/music/scan`
- **Query 参数**：`scan_dir`（可选，扫描指定目录；不传使用默认本地音乐库路径）
- **响应示例 (200 OK)**：
```json
{
  "status": "ok",
  "scanned_count": 42,
  "added_count": 15,
  "updated_count": 0,
  "total_tracks": 42
}
```

### 4.2 检索本地曲库列表
- **路径**：`GET /api/v1/music/tracks`
- **Query 参数**：
  - `keyword`: 标题/艺术家/专辑模糊搜索关键词
  - `source`: `"local_repo"`（默认本地曲库）或 `"netease_cache"`（缓存曲库）
  - `page`: 页码（默认 1）
  - `limit`: 分页大小（默认 50）
- **响应示例 (200 OK)**：
```json
{
  "total": 1,
  "page": 1,
  "limit": 50,
  "tracks": [
    {
      "track_id": "local_9d1a8e7b3c2...",
      "title": "晴天",
      "artist": "周杰伦",
      "album": "叶惠美",
      "duration_seconds": 269.0,
      "format": "flac",
      "bitrate": 982000,
      "file_size": 33182900,
      "stream_url": "http://127.0.0.1:8000/api/v1/music/stream/local_9d1a8e7b3c2..."
    }
  ]
}
```

### 4.3 获取单曲详情
- **路径**：`GET /api/v1/music/tracks/{track_id}`
- **响应**：单曲元数据对象。

### 4.4 HTTP 206 Partial Content 流式传输端点 (MED-02)
- **路径**：`GET /api/v1/music/stream/{track_id}`
- **请求头**：`Range: bytes=start-end`（可选，支持毫秒级快速跳转与断点续传）
- **响应头**：
  - 存在 Range 时返回 `HTTP/1.1 206 Partial Content`
  - `Content-Range: bytes 0-1048575/33182900`
  - `Accept-Ranges: bytes`
  - `Content-Type: audio/flac` 或 `audio/mpeg`

---

## 五、网易云在线曲库与边播边存模块

### 5.1 关键词在线搜索 (NET-02)
- **路径**：`GET /api/v1/music/netease/search`
- **Query 参数**：
  - `keyword`: 必填，歌曲名或歌手
  - `page`: 页码（默认 1）
  - `limit`: 每页条数（默认 20）
- **响应示例 (200 OK)**：
```json
{
  "code": 200,
  "total": 1,
  "songs": [
    {
      "id": 5257138,
      "title": "屋顶",
      "artist": "周杰伦 / 温岚 / 吴宗宪",
      "album": "屋顶",
      "duration_ms": 319000,
      "cover_url": "https://p2.music.126.net/....jpg",
      "cached": false,
      "stream_url": "http://127.0.0.1:8000/api/v1/music/netease/stream/5257138"
    }
  ]
}
```

### 5.2 提取网易云 CDN 真实直链 (NET-04)
- **路径**：`GET /api/v1/music/netease/song_url`
- **Query 参数**：
  - `song_id`: 歌曲 ID
  - `level`: 音质档位，`standard` (标准) / `exhigh` (320k) / `lossless` (无损 FLAC) / `hires` (Hi-Res)
- **响应示例 (200 OK)**：
```json
{
  "code": 200,
  "song_id": 5257138,
  "url": "http://m801.music.126.net/....flac",
  "br": 1619359,
  "size_bytes": 64579972,
  "type": "flac"
}
```

### 5.3 获取歌词与翻译
- **路径**：`GET /api/v1/music/netease/lyric`
- **Query 参数**：`song_id`: 歌曲 ID
- **响应示例 (200 OK)**：
```json
{
  "code": 200,
  "song_id": 5257138,
  "lrc": "[00:00.00] 作曲 : 周杰伦\n[00:01.00] 作词 : 周杰伦...",
  "tlyric": null
}
```

### 5.4 生成心动模式智能推荐队列 (NET-03)
- **路径**：`POST /api/v1/music/netease/intelligence`
- **请求体**：
```json
{
  "seed_song_id": 5257138,
  "playlist_id": null,
  "count": 30
}
```
- **响应示例 (200 OK)**：
```json
{
  "code": 200,
  "mode": "intelligence", // 未登录时自动回退为 "simi_fallback"
  "songs": [ ... ]
}
```

### 5.5 动态“边播边存”流式中继端点 (MED-03)
- **路径**：`GET /api/v1/music/netease/stream/{song_id}`
- **特性**：
  - 若本地缓存已命中：直接调用 `file_chunk_generator` 发送本地文件，支持 HTTP 206。
  - 若未命中：启动双通道管道（Tee-stream），一边分块 Streaming 给车机，一边异步写入磁盘；播放完成自动登记至 SQLite 媒体库。

### 5.6 媒体缓存池状态查询 (MED-04)
- **路径**：`GET /api/v1/music/cache/stats`
- **响应示例 (200 OK)**：
```json
{
  "cache_dir": "/path/to/user/.local/share/myyaris/media/cache",
  "total_files": 12,
  "total_bytes": 451829440,
  "max_bytes": 53687091200, // 50GB 配额
  "usage_percentage": 0.84,
  "tracks_in_db": 12
}
```

### 5.7 手动触发 LRU 淘汰清理 (MED-04)
- **路径**：`POST /api/v1/music/cache/clean`
- **Query 参数**：`target_bytes`（可选，清理至目标字节数以内；不填则按 50GB 阈值清理）

---

## 六、网易云账号授权与保活管理模块

### 6.1 获取扫码 unikey (NET-05)
- **路径**：`GET /api/v1/music/netease/login/qr/key`
- **响应示例 (200 OK)**：
```json
{
  "code": 200,
  "unikey": "df60d379-8308-407f-9fc8-c70f95e1664b"
}
```

### 6.2 生成登录二维码 (NET-05)
- **路径**：`GET /api/v1/music/netease/login/qr/create`
- **Query 参数**：`key`: unikey
- **响应示例 (200 OK)**：
```json
{
  "code": 200,
  "qrurl": "https://music.163.com/login?codekey=df60d379-8308-407f-9fc8-c70f95e1664b",
  "qrimg": "data:image/png;base64,iVBORw0KGgo..."
}
```

### 6.3 轮询检测扫码授权状态 (NET-05)
- **路径**：`GET /api/v1/music/netease/login/qr/check`
- **Query 参数**：`key`: unikey
- **状态码说明**：
  - `800`: 二维码已过期 (`status: "expired"`)
  - `801`: 等待扫码 (`status: "waiting_scan"`)
  - `802`: 手机已扫码待确认 (`status: "waiting_confirm"`)
  - `803`: 授权登录成功 (`status: "authorized"`，Cookie 自动落盘)

### 6.4 账号登录状态查询
- **路径**：`GET /api/v1/music/netease/login/status`
- **响应示例 (已登录)**：
```json
{
  "code": 200,
  "logged_in": true,
  "user_id": 100000001,
  "nickname": "AuthorizedUser",
  "avatar_url": "https://example.com/avatar.jpg",
  "vip_type": 110,
  "cookie_updated_at": "2026-10-12T11:56:23.598281+00:00"
}
```

### 6.5 Cookie / MUSIC_U 直接导入登录 (推荐)
- **路径**：`POST /api/v1/music/netease/login/cookie`
- **说明**：直接注入从电脑浏览器获取的 `MUSIC_U`，彻底规避扫码时的移动端风控。
- **请求体**：
```json
{
  "cookie": "00A6DA25C54D... 或 MUSIC_U=00A6DA25C54D...;"
}
```

### 6.6 手动触发凭证刷新保活
- **路径**：`POST /api/v1/music/netease/login/refresh`
- **说明**：向上游刷新当前 Cookie 有效期。

### 6.7 退出登录并清除 Cookie
- **路径**：`POST /api/v1/music/netease/login/logout`

---

## 七、车机远程控制与状态同步模块

### 7.1 下发远程播放控制指令
- **路径**：`POST /api/v1/music/control/command`
- **鉴权**：手机端或管理员 (`Authorization: Bearer <PHONE_TOKEN>`)
- **请求体**：
```json
{
  "device_id": "car_p3pro", // 默认 car_p3pro
  "action": "play_track", // 见下表
  "payload": {
    "track_id": "netease_5257138",
    "stream_url": "http://127.0.0.1:8000/api/v1/music/netease/stream/5257138",
    "title": "屋顶",
    "artist": "周杰伦 / 温岚"
  }
}
```
- **支持的 Action 指令类型**：
  | Action | 说明 | Payload 参数 |
  | :--- | :--- | :--- |
  | `play_track` | 切歌播放指定音轨 | `track_id`, `stream_url`, `title`, `artist` |
  | `pause` | 暂停播放 | 无 |
  | `resume` | 继续播放 | 无 |
  | `next` | 下一曲 | 无 |
  | `prev` | 上一曲 | 无 |
  | `seek` | 跳转进度 | `position_ms` (毫秒) |
  | `set_loop` | 设置循环模式 | `mode`: `"all"` \| `"single"` \| `"none"` |
  | `set_shuffle` | 设置随机播放 | `shuffle`: `true` \| `false` |
  | `set_volume` | 调节车机软件音量 | `volume`: `0.0` ~ `1.0` |

### 7.2 车机长轮询拉取控制指令
- **路径**：`GET /api/v1/music/control/command/next`
- **鉴权**：车机端 (`X-Device-Token: <CAR_TOKEN>`)
- **Query 参数**：`device_id`（默认 `car_p3pro`）、`timeout`（长轮询超时秒数，默认 30s）
- **响应**：有指令返回指令对象，超时返回 `204 No Content`。

### 7.3 车机上报播放状态与心跳
- **路径**：`POST /api/v1/music/control/status`
- **鉴权**：车机端 (`X-Device-Token: <CAR_TOKEN>`)
- **请求体**：
```json
{
  "device_id": "car_p3pro",
  "playback_state": "playing", // "playing" | "paused" | "stopped" | "buffering"
  "current_track_id": "netease_5257138",
  "position_ms": 45000,
  "duration_ms": 319000,
  "software_volume": 0.85,
  "loop_mode": "all",
  "shuffle_enabled": false
}
```

### 7.4 查询车机当前播放状态
- **路径**：`GET /api/v1/music/control/status`
- **Query 参数**：`device_id`（默认 `car_p3pro`）
- **响应示例 (200 OK)**：
```json
{
  "device_id": "car_p3pro",
  "playback_state": "playing",
  "current_track_id": "netease_5257138",
  "position_ms": 45000,
  "duration_ms": 319000,
  "software_volume": 0.85,
  "loop_mode": "all",
  "shuffle_enabled": false,
  "last_heartbeat_at": "2026-10-12T12:00:45Z",
  "updated_at": "2026-10-12T12:00:45Z"
}
```

---

## 八、全双工 WebSocket 实时通信接口

### 8.1 连接端点
- **路径**：`WSS /api/v1/ws/music`
- **URL 参数**：
  - `token`: 必填鉴权 Token（手机 Token 或车机 Token）
  - `client_type`: `"phone"`（手机客户端）或 `"car"`（车机端）
  - `device_id`: 车机标识（默认 `car_p3pro`）

### 8.2 数据交互协议
连接建立后，服务端首先推送初始快照：
```json
{
  "type": "status_snapshot",
  "data": { ... } // 车机当前播放状态
}
```

#### 客户端发送心跳：
```json
{ "type": "ping" }
```
服务端返回：
```json
{ "type": "pong", "timestamp": "2026-10-12T12:00:00Z" }
```

#### 手机端发送控制指令（即时广播给车机）：
```json
{
  "type": "command",
  "data": {
    "action": "pause"
  }
}
```

#### 车机端上报播放状态更新（即时广播给所有手机客户端）：
```json
{
  "type": "status_update",
  "data": {
    "playback_state": "playing",
    "current_track_id": "netease_5257138",
    "position_ms": 50000,
    "duration_ms": 319000
  }
}
```
