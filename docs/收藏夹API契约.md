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
| `owner_scope` | String(64) | 是 | 作用域键 | 内部唯一作用域键：登录账号为 `"user:<user_id>"`，Legacy 池为 `"__legacy__"` | `"user:usr_123456"` |
| `name` | String(64) | 是 | 无 | 文件夹展示名称，`strip()` 去空白后长度 `1..64` | `"日常通勤"` |
| `name_norm` | String(64) | 是 | 归一化名称 | 内部小写归一化名称 `lower(trim(name))`，与 `owner_scope` 组成数据库级唯一约束 `uq_favorite_folders_scope_name_norm` | `"日常通勤"` |
| `favorite_count` | Integer | 是 | `0` | 响应计算字段：当前文件夹下的收藏地址数量 | `3` |
| `created_at` | DateTime | 是 | UTC 当前时间 | 创建时间（ISO 8601 字符串格式返回） | `"2026-10-18T12:00:00+00:00"` |
| `updated_at` | DateTime | 是 | UTC 当前时间 | 更新时间（ISO 8601 字符串格式返回） | `"2026-10-18T12:00:00+00:00"` |

### 3.2 收藏地址模型 (`Favorite` / 表 `favorites`)

| 字段名 | 类型 | 必填 | 默认值 | 约束说明 | 示例 |
| :--- | :--- | :---: | :--- | :--- | :--- |
| `id` | String(64) | 是 | 自动生成 | 主键，格式 `fav_[12位十六进制]` | `"fav_a1b2c3d4e5f6"` |
| `folder_id` | String(64) | 否 | `null` | 所属文件夹 ID（新库建表含 `REFERENCES favorite_folders(id) ON DELETE SET NULL`；既有库经 `ALTER TABLE ADD COLUMN` 迁移无底层 `REFERENCES` 约束，由应用层原子事务保障），`null` 表示未分类 | `"fld_9a8b7c6d5e4f"` |
| `folder_name` | String(64) | 否 | `null` | 响应冗余字段：所属文件夹名称，未分类时为 `null` | `"日常通勤"` |
| `name` | String(128) | 否 | `null` | 可选自定义名称/标签（如“家”、“公司”）；去前后空白，空字符或纯空白规范化为 `null`，超长（>128）返回 422；可与 `address` 同时为空（依靠经纬度坐标唯一定位） | `"公司"` |
| `address` | String(512) | 否 | `""` | 可选地址文本；缺省、传入 `null` 或纯空白字符均规范化为空字符串 `""`，最大长度 512 字符；响应中固定为非空字符串类型（无详细地址时返回 `""`） | `"北京市海淀区中关村南大街1号"` |
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
  | `offset` | Integer | 否 | 0 | 偏移量 ($\ge 0$)；当 `offset >= total` 时返回 `items: []`、`has_more: false` |
  | `sort_by` | String | 否 | `"created_at"` | 排序字段：`"created_at"` \| `"updated_at"` \| `"name"` |
  | `order` | String | 否 | `"asc"` | 排序方向：`"asc"` \| `"desc"` |
  | `search` | String | 否 | `null` | 文件夹名称关键字模糊搜索 |
- **分页稳定次序与二级 `id` 排序说明**：
  - 后端固定采用二级稳定排序：`ORDER BY <sort_by> ASC, id ASC`（或 `ORDER BY <sort_by> DESC, id DESC`），确保相同时间戳或相同名称下跨页翻页不漏项、不重项。
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
- **校验、数据库唯一约束与并发冲突映射**：
  - 自动去除首尾空白；若为空白或长度超过 64 字符，返回 `HTTP 422 Unprocessable Entity`；
  - 同账号作用域内名称唯一性由「应用层预检 + SQLite 唯一索引 `uq_favorite_folders_scope_name_norm (owner_scope, name_norm)` / `uq_favorite_folders_user_expr` + `IntegrityError` 事务回滚并映射为 `HTTP 409 Conflict`」双重保障，彻底防止并发请求绕过重名校验；
- **成功响应 (`201 Created`)**：返回新建的 `FavoriteFolderResponse` 对象。

### 4.3 重命名文件夹 (Rename Favorite Folder)
- **请求方式 & 路径**：`PATCH /api/v1/favorite-folders/{folder_id}`（同时支持 `PUT`，及 `/api/v1/favorites/folders/{folder_id}`）
- **请求 Body**：
```json
{
  "name": "周末出游"
}
```
- **错误码**：同账号重名（含并发重命名触发数据库唯一约束 `IntegrityError`）返回 `HTTP 409 Conflict`；不存在或非当前账号所有返回 `HTTP 404 Not Found`。

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
  | `offset` | Integer | 否 | 0 | 偏移量 ($\ge 0$)；当 `offset >= total` 时返回 `items: []`、`has_more: false` |
  | `sort_by` | String | 否 | `"created_at"` | `"created_at"` \| `"updated_at"` \| `"name"` |
  | `order` | String | 否 | `"desc"` | `"desc"` \| `"asc"` |
  | `search` | String | 否 | `null` | 关键字模糊搜索（匹配 `name` 或 `address`） |
  | `folder_id` | String | 否 | `null` | 传入具体 `fld_xxx` 筛选该文件夹内地址；传入 `"uncategorized"` / `"null"` / `"none"` 筛选未分类地址；不传则返回全部 |
  | `uncategorized` | Boolean | 否 | `null` | 传 `true` 仅返回未分类地址（`folder_id IS NULL`）；传 `false` 仅返回已分类地址 |
- **分页稳定次序与冲突筛选规则**：
  - **二级 `id` 稳定排序**：固定采用 `ORDER BY <sort_by> DESC/ASC, id DESC/ASC`；
  - **冲突筛选拒绝 (`422`)**：若同时传入 `uncategorized=true` 与具体文件夹 `folder_id=fld_xxx`，属于语义冲突，直接返回 `HTTP 422 Unprocessable Entity`；
  - **不存在或跨账号文件夹筛选 (`404`)**：若传入的 `folder_id` 不存在或不属于当前登录账号，返回 `HTTP 404 Not Found`。
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
- **向后兼容与可选字段说明**：
  - `address` 为**可选字段**（默认 `""`）：用户从地图图钉选点但无详细门牌地址时可缺省、传 `null` 或传空字符串，服务端统一落库为空字符串 `""`，最大 512 字符；
  - `name` 为可选字段（默认 `null`）：可与 `address` 同时缺省；
  - `folder_id` 为可选字段；旧版客户端不传或传 `null`/`""` 时，默认保存为**未分类 (`folder_id: null`)**；
  - 若传入 `folder_id`，必须为当前登录账号自己的有效文件夹，否则返回 `HTTP 404 Not Found`。

### 5.3 编辑修改收藏与移动文件夹 (Update / Move Favorite)
- **请求方式 & 路径**：`PATCH /api/v1/favorites/{id}`（同时兼容 `PUT`）
- **请求 Body 字段与归类语义 (`exclude_unset=True`)**：
  1. **地址文本更新 (`address`)**：
     - **不传 `address` 字段**（如仅传 `{"name": "新名称"}`）：保持原地址文本不变；
     - **显式传入 `null`、`""` 或纯空白字符**：将该地址重置清空为空字符串 `""`；
     - **传入非空字符串**：去除前后空白后更新（最长 512 字符，超长返回 422）；
  2. **归类归属更新 (`folder_id`)**：
     - **不传 `folder_id` 字段**：保持原有所属文件夹不变；
     - **传入 `"folder_id": "fld_xxx"`**：将该地址移动到目标文件夹（须属于同一账号，否则返回 `404`）；
     - **显式传入 `"folder_id": null` 或 `""` 或 `"uncategorized"`**：将该地址移回**未分类 (`folder_id: null`)**。

### 5.4 获取详情与删除收藏项
- **获取详情**：`GET /api/v1/favorites/{id}`
- **删除地址**：`DELETE /api/v1/favorites/{id}`（客户端须先弹窗二次确认）

---

## 6. 全量错误码与客户端重试/幂等语义规范

### 6.1 统一错误状态码表

| HTTP 状态码 | 触发场景 | 客户端处理建议 |
| :--- | :--- | :--- |
| **`401 Unauthorized`** | 未携带会话/Token、Token 为空或登录会话已过期/注销 | 引导用户重新登录或刷新鉴权态 |
| **`403 Forbidden`** | 1. 车机角色 (`car`) 调用收藏夹/文件夹接口；<br>2. Cookie 鉴权写操作 (`POST`/`PATCH`/`PUT`/`DELETE`) 缺失或携带无效 `X-CSRF-Token` | 停止自动重试；检查当前角色或补齐 CSRF Token |
| **`404 Not Found`** | 1. 目标 `favorite_id` 或 `folder_id` 不存在或已被删除；<br>2. 跨账号（含管理员跨用户、账号与 Legacy 池互引）访问或归类引用 | 若为删除操作或按文件夹筛选报 `404`，客户端应回退至「全部/未分类」视图并重新拉取列表 |
| **`409 Conflict`** | 新建或重命名文件夹时，规范化名称 `lower(trim(name))` 在当前账号作用域内已存在（含并发请求触发 SQLite 唯一约束 `IntegrityError`） | 提示用户“该文件夹名称已存在”，并可刷新文件夹列表 |
| **`422 Unprocessable Entity`** | 1. 文件夹名为空/纯空白，或文件夹名超过 64 字符；<br>2. 收藏地址非字符串或超过 512 字符，或名称超过 128 字符；<br>3. 经纬度越界（纬度超出 [-90, 90]，经度超出 [-180, 180]）或非有限数值，或 `coord_system != "wgs84"`；<br>4. `GET /api/v1/favorites` 同时传入 `uncategorized=true` 与具体 `folder_id=fld_xxx` | 修正表单输入或查询参数，禁止原样重试 |

### 6.2 客户端重试与幂等边界规范
1. **重复 `DELETE` 与 `404` 刷新处理**：
   - `DELETE /api/v1/favorite-folders/{folder_id}` 与 `DELETE /api/v1/favorites/{favorite_id}` 首次成功删除返回 `200 OK`；
   - 若首次请求在服务端提交成功后因网络抖动超时，客户端再次发起 `DELETE` 将收到 `404 Not Found`；
   - **客户端规范**：删除请求收到 `200 OK` 或重试收到 `404 Not Found` 时，均应视为目标记录已不存在，立即刷新文件夹列表（`GET /api/v1/favorite-folders`）与收藏地址列表（`GET /api/v1/favorites`），避免 UI 卡在已删除文件夹上。
2. **`POST` 超时严禁盲目自动重试**：
   - **`POST /api/v1/favorites`（无 `idempotency_key`）**：当前接口未设幂等键（`idempotency_key`），也不对相同坐标/地址做唯一性拦截（允许用户收藏同一大厦的不同备注项）。因此**当 `POST /api/v1/favorites` 发生网络超时或连接中断时，客户端严禁静默盲目重试**，否则可能产生重复收藏项；超时后应先拉取列表确认或提示用户手动重试。
   - **`POST /api/v1/favorite-folders`**：受数据库级 `(owner_scope, name_norm)` 唯一索引保护，若首次请求已落库而响应超时，重试同名请求将稳定返回 `409 Conflict`，客户端收到 `409` 后直接刷新文件夹列表即可对齐服务端状态。
3. **`PATCH / PUT` 幂等性**：
   - 更新地址或重命名文件夹为按字段覆盖操作，相同 Payload 重复提交具有状态幂等性。

---

## 7. 数据库持久化、新旧表约束差异与幂等迁移说明

1. **新表创建 vs 既有表 `ALTER TABLE` 迁移的底层约束差异（如实声明）**：
   - **全新初始化的数据库（`Base.metadata.create_all`）**：`favorites` 表建表 DDL 包含 `folder_id VARCHAR(64) REFERENCES favorite_folders(id) ON DELETE SET NULL` 外键声明；`favorite_folders` 表包含 `UniqueConstraint("owner_scope", "name_norm", name="uq_favorite_folders_scope_name_norm")`。
   - **既有数据库增量迁移（如 R9000P 生产库 `run_db_migrations`）**：
     - 对既有的 `favorites` 表，SQLite 通过 `ALTER TABLE favorites ADD COLUMN folder_id VARCHAR(64)` 新增列；受 SQLite `ALTER TABLE ADD COLUMN` 语法特性决定，该增量列**在底层表结构上不附带 `REFERENCES favorite_folders(id)` 外键约束**（避免重建整表带来生产数据风险）。
     - 对 `favorite_folders` 表，迁移脚本幂等补齐 `owner_scope` 与 `name_norm` 列、回填既有数据，并创建两个数据库级唯一索引：`uq_favorite_folders_scope_name_norm ON favorite_folders (owner_scope, name_norm)` 与表达式唯一索引 `uq_favorite_folders_user_expr ON favorite_folders (coalesce(user_id, '__legacy__'), is_legacy, lower(trim(name)))`。
2. **应用层原子事务与读取兜底保护**：
   - 鉴于增量迁移后的 `favorites.folder_id` 不依赖底层 SQLite 外键级联，后端在应用层实施了完整闭环保护：
     1. **写入强校验**：`POST / PATCH / PUT /api/v1/favorites` 写入非空 `folder_id` 前，強制通过 `_get_owned_folder_or_404` 校验目标文件夹存在且归属同一账号作用域；
     2. **删除文件夹单事务归回未分类**：`DELETE /api/v1/favorite-folders/{folder_id}` 在**同一个 SQLAlchemy 事务**内先执行 `UPDATE favorites SET folder_id = NULL, updated_at = :now WHERE folder_id = :folder_id`，再执行 `DELETE FROM favorite_folders WHERE id = :folder_id`，统一 `db.commit()`；
     3. **读取孤儿引用自愈**：`_to_favorite_response` 序列化时若发现 `row.folder` 为空或作用域不一致，自动将响应中的 `folder_id` 与 `folder_name` 归一化为 `null`。
3. **生产数据零破坏保障**：
   - 迁移全程仅做幂等 `CREATE TABLE IF NOT EXISTS`、`ALTER TABLE ADD COLUMN`、`UPDATE` 空值回填与 `CREATE [UNIQUE] INDEX IF NOT EXISTS`，绝不执行 `DROP TABLE` 或清空既有用户与收藏数据。


