# iPhone 快捷指令“发送到车机”配置与使用指南

本指南详细说明如何在 iPhone 上通过“快捷指令”（Shortcuts）配置“**发送到车机**”动作，将 Google Maps 分享链接或坐标直接推送到 R9000P 后端服务，并自动流转至 Ottocast P3 Pro 车机调起 CAR NAVITIME 导航。

---

## 1. 前置网络与安全要求

1. **Tailscale 私网接入**：
   - iPhone 必须安装并登录 Tailscale，且处于已连接状态（与 R9000P 处于同一 Tailscale Tailnet）。
   - 后端统一 HTTPS 接入地址：
     ```text
     https://myyaris.example.com
     ```
2. **手机鉴权令牌（PHONE_TOKEN）**：
   - 接口需携带 `Authorization: Bearer <YOUR_PHONE_TOKEN>` 请求头。
   - **安全提示**：请在快捷指令中通过独立的文本变量保存您的令牌，**切勿将真实令牌写入公开文档或代码仓库**。

---

## 2. 快捷指令基础属性设置

打开 iPhone 的“快捷指令”App，新建快捷指令，点击顶部名称重命名为：**发送到车机**。

点击底部的“详细信息 (i)”图标，开启以下开关：
- [x] **在共享表单中显示**（Show in Share Sheet）
- **接收的内容类型**：勾选 **URL**、**文本**、**位置**（Safari 网页、Google Maps 分享、纯文本等）。
- [x] 若无输入，可配置为“询问输入”（用于手动输入经纬度）。

---

## 3. 详细逻辑步骤创建（双入口支持）

### 步骤 A：判断输入类型与生成幂等键

1. **获取随机 UUID（幂等键）**：
   - 添加动作：`生成随机 UUID`（Generate UUID）
   - 将结果命名为变量：`idempotency_key`

2. **判断输入分支**：
   - 添加动作：`如果`（If）快捷指令输入 `包含` `http`（判断是否为分享链接）：
     - **分支 1（分享链接）**：
       - 从输入中提取 URL：`获取 URL` 变量设为 `share_url`
       - 构建字典（Dictionary）`payload`：
         - `input_type` (文本): `share_link`
         - `url` (文本): `share_url`
         - `idempotency_key` (文本): `idempotency_key`
         - `target_device_id` (文本): `car_p3pro`
     - **分支 2（经纬度/坐标输入）**：
       - 如果输入匹配经纬度数字正则或手动输入坐标：
         - 拆分出 `latitude`（纬度，如 `34.399133`）和 `longitude`（经度，如 `132.711467`）
         - 构建子字典 `coord_dict`：
           - `latitude` (数字): `34.399133`
           - `longitude` (数字): `132.711467`
           - `coord_system` (文本): `wgs84`
         - 构建字典 `payload`：
           - `input_type` (文本): `coords`
           - `coordinate` (字典): `coord_dict`
           - `idempotency_key` (文本): `idempotency_key`
           - `target_device_id` (文本): `car_p3pro`
   - 结束如果

---

## 4. 调用后端 API（网络请求配置）

添加动作：**获取 URL 内容**（Get Contents of URL）

- **URL**：
  ```text
  https://myyaris.example.com/destinations
  ```
- **方法**：`POST`
- **请求头（Headers）**：
  - `Content-Type`: `application/json`
  - `Accept`: `application/json`
  - `Authorization`: `Bearer <YOUR_PHONE_TOKEN>`（此处替换为您的手机端专用 Token）
- **请求体（Request Body）**：选择 `JSON`，传入上述构建好的 `payload` 字典。

---

## 5. 请求载荷严格 Schema 对照表

向 `POST /destinations` 提交的请求格式严格遵循服务端 Pydantic 契约：

### 模式一：分享链接（`share_link`）
```json
{
  "input_type": "share_link",
  "url": "https://maps.app.goo.gl/EXAMPLE",
  "idempotency_key": "550e8400-e29b-41d4-a716-446655440000",
  "target_device_id": "car_p3pro"
}
```

### 模式二：直传经纬度（`coords`）
```json
{
  "input_type": "coords",
  "coordinate": {
    "latitude": 34.399133,
    "longitude": 132.711467,
    "coord_system": "wgs84"
  },
  "idempotency_key": "550e8400-e29b-41d4-a716-446655440001",
  "target_device_id": "car_p3pro"
}
```

---

## 6. 响应解析与准确反馈文案

在“获取 URL 内容”后，添加动作**获取字典值**（Get Dictionary Value）提取键 `status`：

根据返回的 `status` 字段显示准确的通知或提示弹窗（**严禁仅凭 HTTP 200 就声称车机已完成导航**）：

1. **`status == "resolved"`**：
   - 提取 `task_id`。
   - **反馈文案**：
     > 🚗 **已生成车机导航任务**
     > 任务编号: `[task_id]`
     > 状态: `queued`（已进入队列，等待车机前台长轮询接收拉起）
2. **`status == "needs_clarification"`**：
   - 提取 `clarification_question` 或 `candidates` 候选列表。
   - **反馈文案**：
     > ⚠️ **地点存在歧义，需进一步确认**
     > 原因: 检索到多个合理匹配项，请在车机或手机端选择确认候选。
3. **`status == "failed"`**：
   - 提取 `error_message`。
   - **反馈文案**：
     > ❌ **目的地解析失败**
     > 原因: `[error_message]`

---

## 7. 限制与注意事项

1. **短链接解析限制**：
   - 服务端内置严密的 SSRF 防御机制（禁止内网重定向、过滤非信任域名）。
   - **不承诺支持所有第三方特殊短链接**。优先推荐在 Google Maps 中选择地点后直接分享完整链接，或直接提交准确坐标。
2. **车机接收时机**：
   - 车机端（MyYaris App）必须在前台运行且已开启“长轮询接收”。
   - 若车机离线或未在前台运行，任务将在服务端保留（默认 60 分钟有效），待车机上线后自动收取。
