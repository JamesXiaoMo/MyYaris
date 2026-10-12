# MyYaris 收藏夹 (Favorites) API 契约与三端协同规范

**版本**：V1.0.0  
**生效日期**：2026-10-13  
**状态**：已冻结实施  
**维护方**：后端系统组  
**对接方**：iOS 端（行驶页收藏夹模块）、车机端（预留后续只读联动）

---

## 1. 业务背景与架构边界

### 1.1 业务背景
iOS App 第二页功能定位由原「导航」调整升级为「行驶」。在此背景下新增**「收藏夹 (Favorites)」**模块，支持车主用户手动保存常用地址及其精确经纬度（如家、公司、充电站、常去地点），并提供全生命周期的增删改查管理能力。

### 1.2 职责边界与明确非目标 (Non-Goals)
1. **初版核心职责**：
   - 纯粹负责地址文本与经纬度坐标的持久化存储与管理。
2. **严禁越界行为 (当前版本非目标)**：
   - **不自动触发逆地理编码 (Reverse Geocoding)**：不向 Nominatim 发起逆地理或联网补全，输入什么地址就保存什么地址。
   - **不自动创建车机导航任务**：新增或编辑收藏夹地址**绝不**自动触发 `tasks` 生成或向车机派发目的地导航；若用户后续点击收藏夹项发起导航，由客户端显式调用导航派发接口 `POST /api/v1/tasks/destination`。
   - **不猜测互换经纬度**：纬度与经度严格校验，若越界或颠倒直接返回 422 拒绝，严禁后端臆测调换。
   - **删除二次确认由客户端主导**：客户端 UI 必须弹出确认对话框，用户确认后再调用 DELETE 接口。

---

## 2. 鉴权与安全访问边界 (Authentication & Security)

### 2.1 鉴权要求与账号模型边界
所有收藏夹接口均受权限保护，**严禁任何形式的匿名开放访问**：
- **允许角色**：`phone` (iOS 客户端) 或 `admin` (管理员)。
- **禁止角色**：`car` (车载平板端暂无写权限，若调用直接返回 HTTP 403 Forbidden)。
- **数据归属说明（自用共享收藏）**：当前系统为单车车主私有后端体系（基于 `PHONE_TOKEN` 鉴权）。`created_by` 字段记录当前 Token 角色身份（如 `phone_client` 或 `admin`），代表**整车自用/家庭共享收藏夹池**，**并非具备独立注册用户体系的个人多账户强隔离**。

### 2.2 请求鉴权头
支持以下两种标准头：
```http
Authorization: Bearer <PHONE_TOKEN>
```
或
```http
X-Device-Token: <PHONE_TOKEN>
```

### 2.3 异常状态码
- **HTTP 401 Unauthorized**：未携带 Token、Token 为空或 Token 无效。
- **HTTP 403 Forbidden**：携带了非 phone/admin 角色的凭证（如车机端 token 越权访问）。

---

## 3. 数据模型定义 (Data Schema)

### 3.1 实体模型 (`Favorite`)

| 字段名 | 类型 | 必填 | 默认值 | 约束说明 | 示例 |
| :--- | :--- | :---: | :--- | :--- | :--- |
| `id` | String(64) | 是 | 自动生成 | 主键，格式 `fav_[12位十六进制/UUID]` | `"fav_a1b2c3d4e5f6"` |
| `name` | String(128) | 否 | `null` | 可选自定义名称/标签（如“家”、“公司”） | `"公司"` |
| `address` | String(512) | 是 | 无 | 详细地址文本，去除前后空格后非空 | `"北京市海淀区中关村南大街1号"` |
| `latitude` | Float (Double) | 是 | 无 | 纬度，有限数值，范围 `[-90.0, 90.0]` | `39.9567` |
| `longitude` | Float (Double) | 是 | 无 | 经度，有限数值，范围 `[-180.0, 180.0]` | `116.3212` |
| `coord_system` | String(32) | 否 | `"wgs84"` | **严格仅支持 `"wgs84"`**，与 NAVITIME WGS84 流程对齐 | `"wgs84"` |
| `created_by` | String(64) | 否 | `null` | 归属账号身份标识（如 `phone_client`） | `"phone_client"` |
| `created_at` | DateTime | 是 | UTC 当前时间 | 创建时间（ISO 8601 字符串格式返回） | `"2026-10-13T00:30:00+00:00"` |
| `updated_at` | DateTime | 是 | UTC 当前时间 | 更新时间（ISO 8601 字符串格式返回） | `"2026-10-13T00:30:00+00:00"` |

### 3.2 坐标与输入校验规则
1. **地址校验**：
   - 必须为字符串类型，`strip()` 去除首尾空白后字符长度必须大于 0；
   - 最大长度限制为 500 个字符；
   - 空字符串、全空格字符串均拒绝并返回 HTTP 422。
2. **坐标数值校验**：
   - `latitude`：必须为有限浮点数（非 `NaN`、非 `Infinity`），且满足 $-90.0 \le latitude \le 90.0$；
   - `longitude`：必须为有限浮点数（非 `NaN`、非 `Infinity`），且满足 $-180.0 \le longitude \le 180.0$；
   - 超出区间时严格报错拒绝，不执行任何猜测调换。
3. **名称字段 (`name`)**：
   - 选填；若传入空字符串或全空格，后端自动转换为 `null`；最大长度 100 字符。
4. **坐标系字段 (`coord_system`)**：
   - 选填，默认 `"wgs84"`；
   - **坐标系安全约束**：首版**严格仅接受 `"wgs84"`**（大小写不敏感，统一归一化为小写）。若传入非 `wgs84`（如 `"gcj02"`、`"bd09"`）直接返回 HTTP 422 拒绝。因当前未实装经严格验证的火星坐标转换算法，坚决不默默转换，严禁让非 WGS84 坐标被当作 WGS84 派发至 NAVITIME 导致导航偏移。

---

## 4. RESTful API 接口规范

### 4.1 获取收藏夹列表 (List Favorites)
- **请求方式**：`GET`
- **请求路径**：`/api/v1/favorites`
- **Query 参数**：
  | 参数名 | 类型 | 必填 | 默认值 | 说明 |
  | :--- | :--- | :---: | :--- | :--- |
  | `limit` | Integer | 否 | 50 | 分页每页数量 (1 ~ 100) |
  | `offset` | Integer | 否 | 0 | 偏移量 ($\ge 0$) |
  | `sort_by` | String | 否 | `"created_at"` | 排序字段：`"created_at"` \| `"updated_at"` \| `"name"` |
  | `order` | String | 否 | `"desc"` | 排序方向：`"desc"` \| `"asc"` |
  | `search` | String | 否 | `null` | 关键字模糊搜索（匹配 `name` 或 `address`） |

- **成功响应**：`HTTP 200 OK`
```json
{
  "items": [
    {
      "id": "fav_08a7b9c1d2e3",
      "name": "公司",
      "address": "北京市海淀区中关村南大街1号",
      "latitude": 39.9567,
      "longitude": 116.3212,
      "coord_system": "wgs84",
      "created_at": "2026-10-13T00:30:00+00:00",
      "updated_at": "2026-10-13T00:30:00+00:00"
    }
  ],
  "total": 1,
  "limit": 50,
  "offset": 0
}
```

---

### 4.2 创建收藏夹项 (Create Favorite)
- **请求方式**：`POST`
- **请求路径**：`/api/v1/favorites`
- **Content-Type**：`application/json`
- **请求 Body**：
```json
{
  "name": "家",                      // 可选，未填或传 null 均可
  "address": "北京市朝阳区北苑路168号",  // 必填，非空字符串
  "latitude": 40.0381,                // 必填，-90.0 ~ 90.0
  "longitude": 116.4258,              // 必填，-180.0 ~ 180.0
  "coord_system": "wgs84"             // 可选，默认 wgs84
}
```
- **成功响应**：`HTTP 201 Created`
```json
{
  "id": "fav_e4f5a6b7c8d9",
  "name": "家",
  "address": "北京市朝阳区北苑路168号",
  "latitude": 40.0381,
  "longitude": 116.4258,
  "coord_system": "wgs84",
  "created_at": "2026-10-13T00:31:00+00:00",
  "updated_at": "2026-10-13T00:31:00+00:00"
}
```
- **校验失败响应**：`HTTP 422 Unprocessable Entity`
```json
{
  "detail": [
    {
      "loc": ["body", "latitude"],
      "msg": "Latitude must be between -90.0 and 90.0",
      "type": "value_error"
    }
  ]
}
```

---

### 4.3 获取收藏详情 (Get Favorite Detail)
- **请求方式**：`GET`
- **请求路径**：`/api/v1/favorites/{id}`
- **成功响应**：`HTTP 200 OK`
```json
{
  "id": "fav_e4f5a6b7c8d9",
  "name": "家",
  "address": "北京市朝阳区北苑路168号",
  "latitude": 40.0381,
  "longitude": 116.4258,
  "coord_system": "wgs84",
  "created_at": "2026-10-13T00:31:00+00:00",
  "updated_at": "2026-10-13T00:31:00+00:00"
}
```
- **不存在响应**：`HTTP 404 Not Found`
```json
{
  "detail": "Favorite 'fav_nonexistent' not found."
}
```

---

### 4.4 编辑修改收藏 (Update Favorite)
- **请求方式**：`PATCH`（同时兼容 `PUT`）
- **请求路径**：`/api/v1/favorites/{id}`
- **Content-Type**：`application/json`
- **请求 Body**（所有字段均为选填，仅更新传入的字段）：
```json
{
  "name": "我的常去地点",
  "address": "北京市朝阳区望京SOHO",
  "latitude": 39.9982,
  "longitude": 116.4815
}
```
- **成功响应**：`HTTP 200 OK`
```json
{
  "id": "fav_e4f5a6b7c8d9",
  "name": "我的常去地点",
  "address": "北京市朝阳区望京SOHO",
  "latitude": 39.9982,
  "longitude": 116.4815,
  "coord_system": "wgs84",
  "created_at": "2026-10-13T00:31:00+00:00",
  "updated_at": "2026-10-13T00:35:00+00:00"
}
```
- **校验失败**：`HTTP 422 Unprocessable Entity`
- **不存在响应**：`HTTP 404 Not Found`

---

### 4.5 删除收藏项 (Delete Favorite)
- **请求方式**：`DELETE`
- **请求路径**：`/api/v1/favorites/{id}`
- **交互约束**：客户端必须在调用此接口前向用户弹出二次确认提示（例如：“确定删除此收藏地点吗？”）。
- **成功响应**：`HTTP 200 OK`
```json
{
  "status": "ok",
  "deleted_id": "fav_e4f5a6b7c8d9",
  "message": "Favorite deleted successfully."
}
```
- **不存在响应**：`HTTP 404 Not Found`

---

## 5. 数据库持久化与平滑迁移说明

1. **表名与表结构**：`favorites`
   - 使用 SQLAlchemy 模型注册于 `Base.metadata`；
   - 应用启动时通过 `Base.metadata.create_all(bind=engine)` 自动检测并创建表结构；
   - **完全无损迁移**：不修改、不删除现有 `tasks`、`destinations`、`music_commands`、`media_tracks` 等任何表结构和历史数据。
2. **并发与事务安全**：
   - SQLite 维持 WAL（Write-Ahead Logging）模式与 30s busy timeout，支持多客户端高并发读与单写入事务；
   - 编辑与删除基于行主键，单条原子事务提交。
3. **持久化验证说明**：
   - 自动化测试通过独立新建数据库连接会话 (`SessionLocal`) 验证数据落盘与读取，证明记录已在 SQLite 磁盘文件中物理持久化；此测试验证的是独立会话与数据库连接跨度的数据持久性，而非操作系统进程重启测试。

---

## 6. R9000P 生产联调与访问指引

- **生产服务基础地址**：`https://myyaris.example.com`
- **收藏夹 API 基础路径**：`https://myyaris.example.com/api/v1/favorites`
- **鉴权要求**：配置 iOS 请求头的 `Authorization: Bearer <PHONE_TOKEN>`
- **网络约束**：通过 Tailscale 内部专网与 HTTPS 安全通道交互，不触碰外部公网域名解析，不触及 Apple 推送服务。
