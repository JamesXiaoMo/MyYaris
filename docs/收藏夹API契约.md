# MyYaris 收藏夹与单层分类文件夹 (Favorites & Folders) API 契约与三端协同规范

**版本**：V2.0.0  
**生效日期**：2026-10-18  
**状态**：已冻结实施  
**维护方**：后端系统组  
**对接方**：iOS 端（行驶页收藏抽屉与分类管理模块）、车机端（预留后续只读联动）

---

## 1. 业务背景与架构边界

### 1.1 业务背景
iOS App 第二页「行驶」提供底部收藏抽屉，支持车主将常用地址（如家、公司、充电站、常去地点）按**单层文件夹**（如“通勤”、“旅行”）或**未分类**进行组织管理，并同步至后端 SQLite 数据库。

### 1.2 职责边界与明确非目标 (Non-Goals)
1. **核心职责**：
   - 负责单层收藏文件夹（`FavoriteFolder`）的增删改查；
   - 负责地址文本、WGS84 经纬度坐标及所属文件夹归类（`Favorite.folder_id`）的持久化存储与管理；
   - 删除非空文件夹时，**在同一数据库事务中将其下所有地址的 `folder_id` 置为 `NULL`（自动移回未分类）**，严禁级联删除用户已保存的地址。
2. **严禁越界行为 (当前版本非目标)**：
   - **仅支持单层文件夹**：不支持嵌套子文件夹、标签系统、跨账号共享文件夹或复杂权限树；
   - **不提供后端 POI / 地点搜索接口**：地图地点搜索（如搜索“麦当劳”）由 iOS 客户端本地 `MKLocalSearch` 完成，后端仅接收已选定结果（名称、地址、WGS84 坐标、可选 `folder_id`）进行保存；
   - **不自动触发逆地理编码 (Reverse Geocoding)**：输入什么地址就保存什么地址；
   - **不自动创建车机导航任务**：新增或编辑收藏夹/文件夹**绝不**自动生成 `tasks` 或向车机派发导航；用户点击地址并在客户端二次确认后，才调用 `POST /api/v1/destinations/resolve` 与 `POST /api/v1/tasks/destination`；
   - **不猜测互换经纬度**：纬度与经度严格校验，越界直接返回 422 拒绝。

---

## 2. 鉴权与账号隔离安全边界 (Authentication & Account Isolation)

### 2.1 鉴权要求与严格账号隔离
所有收藏夹与文件夹接口均受权限保护，**严禁匿名开放访问**：
- **允许身份**：
  1. **已登录账号会话 (`user` / `admin`)**：通过 `Authorization: Bearer <session_id>` 或会话 Cookie（写操作需 `X-CSRF-Token`）鉴权；
  2. **过渡期 Legacy 静态凭据 (`phone` / `admin`)**：通过 `Authorization: Bearer <PHONE_TOKEN>` 或 `X-Device-Token: <PHONE_TOKEN>` 鉴权。
- **禁止角色**：`car`（车载平板端调用直接返回 `HTTP 403 Forbidden`）。
- **严格单账号隔离规则（含管理员）**：
  - 每个登录账号（`user_id` 非空）拥有完全独立的文件夹与收藏地址命名空间（`user_id == current_user.user_id` 且 `is_legacy == false`）；
  - 过渡期静态 Token（`user_id` 为空）仅访问 Legacy 共享池（`user_id IS NULL` / `is_legacy == true`）；
  - **严禁跨账号引用（包括管理员账号）**：任何账号（含 `role == "admin"`）均不得查看、修改、删除其他账号的文件夹/地址，也不得将地址创建或移动到其他账号（或 Legacy 池）的文件夹中，违者一律返回 `HTTP 404 Not Found`。

---

## 3. 数据模型定义 (Data Schema)

### 3.1 收藏文件夹模型 (`FavoriteFolder` / 表 `favorite_folders`)

| 字段名 | 类型 | 必填 | 默认值 | 约束说明 | 示例 |
| :--- | :--- | :---: | :--- | :--- | :--- |
| `id` | String(64) | 是 | 自动生成 | 主键，格式 `fld_[12位十六进制]` | `"fld_9a8b7c6d5e4f"` |
| `user_id` | String(64) | 否 | 当前账号ID | 外键关联 `users.id (ON DELETE CASCADE)`；Legacy 模式为 `null` | `"usr_123456"` |
| `is_legacy` | Boolean | 是 | `false` | 是否属于过渡期 Legacy Token 池 | `false` |
| `name` | String(64) | 是 | 无 | 文件夹名称，`strip()` 去空白后长度 `1..64`，同账号内大小写不敏感唯一 | `"日常通勤"` |
| `favorite_count` | Integer | 是 | `0` | 响应计算字段：当前文件夹下的收藏地址数量 | `3` |
| `created_at` | DateTime | 是 | UTC 当前时间 | 创建时间（ISO 8601 字符串格式返回） | `"2026-10-18T12:00:00+00:00"` |
| `updated_at` | DateTime | 是 | UTC 当前时间 | 更新时间（ISO 8601 字符串格式返回） | `"2026-10-18T12:00:00+00:00"` |

### 3.2 收藏地址模型 (`Favorite` / 表 `favorites`)

| 字段名 | 类型 | 必填 | 默认值 | 约束说明 | 示例 |
| :--- | :--- | :---: | :--- | :--- | :--- |
| `id` | String(64) | 是 | 自动生成 | 主键，格式 `fav_[12位十六进制]` | `"fav_a1b2c3d4e5f6"` |
| `folder_id` | String(64) | 否 | `null` | 所属文件夹 ID（外键 `favorite_folders.id ON DELETE SET NULL`），`null` 表示未分类 | `"fld_9a8b7c6d5e4f"` |
| `folder_name` | String(64) | 否 | `null` | 响应冗余字段：所属文件夹名称，未分类时为 `null` | `"日常通勤"` |
| `name` | String(128) | 否 | `null` | 可选自定义名称/标签（如“家”、“公司”） | `"公司"` |
| `address` | String(512) | 是 | 无 | 详细地址文本，去除前后空格后非空 | `"北京市海淀区中关村南大街1号"` |
| `latitude` | Float (Double) | 是 | 无 | 纬度，有限数值，范围 `[-90.0, 90.0]` | `39.9567` |
| `longitude` | Float (Double) | 是 | 无 | 经度，有限数值，范围 `[-180.0, 180.0]` | `116.3212` |
| `coord_system` | String(32) | 否 | `"wgs84"` | **严格仅支持 `"wgs84"`**，传入 `gcj02`/`bd09` 返回 422 | `"wgs84"` |
| `created_at` | DateTime | 是 | UTC 当前时间 | 创建时间（ISO 8601 字符串格式返回） | `"2026-10-18T12:00:00+00:00"` |
| `updated_at` | DateTime | 是 | UTC 当前时间 | 更新时间（ISO 8601 字符串格式返回） | `"2026-10-18T12:00:00+00:00"` |

---

## 4. 收藏文件夹 API 规范 (`/api/v1/favorite-folders`)

> **路径兼容说明**：所有文件夹接口主路径为 `/api/v1/favorite-folders`，同时完整兼容别名路径 `/api/v1/favorites/folders`。

### 4.1 获取文件夹列表 (List Favorite Folders)
- **请求方式 & 路径**：`GET /api/v1/favorite-folders`（或 `GET /api/v1/favorites/folders`）
- **Query 参数**：
  | 参数名 | 类型 | 必填 | 默认值 | 说明 |
  | :--- | :--- | :---: | :--- | :--- |
  | `limit` | Integer | 否 | 50 | 分页每页数量 (1 ~ 100) |
  | `offset` | Integer | 否 | 0 | 偏移量 ($\ge 0$) |
  | `sort_by` | String | 否 | `"created_at"` | 排序字段：`"created_at"` \| `"updated_at"` \| `"name"` |
  | `order` | String | 否 | `"asc"` | 排序方向：`"asc"` \| `"desc"` |
  | `search` | String | 否 | `null` | 文件夹名称关键字模糊搜索 |
- **成功响应 (`200 OK`)**：
```json
{
  "items": [
    {
      "id": "fld_9a8b7c6d5e4f",
      "name": "日常通勤",
      "favorite_count": 2,
      "created_at": "2026-10-18T12:00:00+00:00",
      "updated_at": "2026-10-18T12:00:00+00:00"
    }
  ],
  "total": 1,
  "limit": 50,
  "offset": 0,
  "has_more": false,
  "uncategorized_count": 1
}
```

### 4.2 创建文件夹 (Create Favorite Folder)
- **请求方式 & 路径**：`POST /api/v1/favorite-folders`（或 `POST /api/v1/favorites/folders`）
- **请求 Body**：
```json
{
  "name": "日常通勤"
}
```
- **校验与错误码**：
  - 自动去除首尾空白；若为空白或长度超过 64 字符，返回 `HTTP 422 Unprocessable Entity`；
  - 若当前账号下已存在同名文件夹（忽略大小写），返回 `HTTP 409 Conflict`；
- **成功响应 (`201 Created`)**：返回新建的 `FavoriteFolderResponse` 对象。

### 4.3 重命名文件夹 (Rename Favorite Folder)
- **请求方式 & 路径**：`PATCH /api/v1/favorite-folders/{folder_id}`（同时支持 `PUT`，及 `/api/v1/favorites/folders/{folder_id}`）
- **请求 Body**：
```json
{
  "name": "周末出游"
}
```
- **错误码**：同账号重名返回 `HTTP 409 Conflict`；不存在或非当前账号所有返回 `HTTP 404 Not Found`。

### 4.4 删除文件夹 (Delete Favorite Folder — 地址自动归回未分类)
- **请求方式 & 路径**：`DELETE /api/v1/favorite-folders/{folder_id}`（或 `DELETE /api/v1/favorites/folders/{folder_id}`）
- **事务级安全语义**：
  - 在单个数据库事务中，先将该文件夹下所有属于当前账号的地址 `folder_id` 更新为 `NULL`（回到未分类），再删除该文件夹记录；
  - **绝不删除任何收藏地址**。
- **成功响应 (`200 OK`)**：
```json
{
  "status": "ok",
  "deleted_id": "fld_9a8b7c6d5e4f",
  "moved_to_uncategorized_count": 2,
  "message": "Favorite folder deleted successfully; addresses moved to uncategorized."
}
```

---

## 5. 收藏地址 API 规范 (`/api/v1/favorites`)

### 5.1 获取收藏夹列表与分类筛选 (List Favorites)
- **请求方式 & 路径**：`GET /api/v1/favorites`
- **Query 参数**：
  | 参数名 | 类型 | 必填 | 默认值 | 说明 |
  | :--- | :--- | :---: | :--- | :--- |
  | `limit` | Integer | 否 | 50 | 分页每页数量 (1 ~ 100) |
  | `offset` | Integer | 否 | 0 | 偏移量 ($\ge 0$) |
  | `sort_by` | String | 否 | `"created_at"` | `"created_at"` \| `"updated_at"` \| `"name"` |
  | `order` | String | 否 | `"desc"` | `"desc"` \| `"asc"` |
  | `search` | String | 否 | `null` | 关键字模糊搜索（匹配 `name` 或 `address`） |
  | `folder_id` | String | 否 | `null` | 传入具体 `fld_xxx` 筛选该文件夹内地址；传入 `"uncategorized"` / `"null"` 筛选未分类地址；不传则返回全部 |
  | `uncategorized` | Boolean | 否 | `null` | 传 `true` 仅返回未分类地址（`folder_id IS NULL`）；传 `false` 仅返回已分类地址 |
- **成功响应 (`200 OK`)**：
```json
{
  "items": [
    {
      "id": "fav_08a7b9c1d2e3",
      "folder_id": "fld_9a8b7c6d5e4f",
      "folder_name": "日常通勤",
      "name": "公司",
      "address": "北京市海淀区中关村南大街1号",
      "latitude": 39.9567,
      "longitude": 116.3212,
      "coord_system": "wgs84",
      "created_at": "2026-10-18T12:01:00+00:00",
      "updated_at": "2026-10-18T12:01:00+00:00"
    }
  ],
  "total": 1,
  "limit": 50,
  "offset": 0,
  "has_more": false
}
```

### 5.2 创建收藏夹项 (Create Favorite)
- **请求方式 & 路径**：`POST /api/v1/favorites`
- **请求 Body**：
```json
{
  "name": "公司",
  "address": "北京市海淀区中关村南大街1号",
  "latitude": 39.9567,
  "longitude": 116.3212,
  "coord_system": "wgs84",
  "folder_id": "fld_9a8b7c6d5e4f"
}
```
- **向后兼容与归类说明**：
  - `folder_id` 为可选字段；旧版客户端不传或传 `null`/`""` 时，默认保存为**未分类 (`folder_id: null`)**；
  - 若传入 `folder_id`，必须为当前登录账号自己的有效文件夹，否则返回 `HTTP 404 Not Found`。

### 5.3 编辑修改收藏与移动文件夹 (Update / Move Favorite)
- **请求方式 & 路径**：`PATCH /api/v1/favorites/{id}`（同时兼容 `PUT`）
- **请求 Body 归类语义 (`exclude_unset=True`)**：
  1. **不传 `folder_id` 字段**（如仅传 `{"name": "新名称"}`）：保持原有所属文件夹不变；
  2. **传入 `"folder_id": "fld_xxx"`**：将该地址移动到目标文件夹（须属于同一账号，否则返回 `404`）；
  3. **显式传入 `"folder_id": null` 或 `""` 或 `"uncategorized"`**：将该地址移回**未分类 (`folder_id: null`)**。

### 5.4 获取详情与删除收藏项
- **获取详情**：`GET /api/v1/favorites/{id}`
- **删除地址**：`DELETE /api/v1/favorites/{id}`（客户端须先弹窗二次确认）

---

## 6. 数据库持久化与幂等迁移说明

1. **表结构与启动迁移 (`run_db_migrations`)**：
   - 新增 `favorite_folders` 表；
   - 在既有 `favorites` 表上幂等检测并执行 `ALTER TABLE favorites ADD COLUMN folder_id VARCHAR(64)`，同时建立 `ix_favorites_folder_id` 与 `ix_favorite_folders_user_id` 索引；
   - 既有未归类地址的 `folder_id` 自动保持为 `NULL`（未分类），100% 无损兼容历史数据。

