# Android 听时奖励分析与实施计划

## 目标与进度

XMPlus 使用已有账号登录态，按任务参数领取正式版与极速版听时。安卓账号页提供手动入口，已有自动领取开关每 5 分钟触发一次领取流程。正式版使用单独保存的设备 ID，极速版沿用账号设备 ID。

分析样本为正式版 `9.5.31.3` 与极速版 `3.5.15.3`。接口字段来自本机 APK 静态分析与实机请求；临时流量文件已清理，以下字段和结果供后续继续分析。

## 正式版调用链

1. `POST /mobile-album/album/replaceConfig` 返回 `albumSubscript`，从中提取 `sceneInfo`、`freeListenExt`、`newFreeCrowd`。
2. `GET /incentive/ting/currentDuration` 查询余额，`GET /incentive/ting/durationConfig` 查询时长配置，`GET /incentive/ting/recAlbumInfo` 下发 `bigDurationTask.adTasks`。`taskType=2` 表示浏览，`taskType=3` 表示视频；四项完成后，主任务 `status=2` 进入最终领取阶段，`status=3` 表示已领取。
3. 浏览任务先请求 `POST /adx/init`，从 `slots` 按 `positionName=inspire_video_wake_end` 读取当前 `id`，再将该值作为 `slotId` 请求 `POST /adx/ad`。从广告响应读取 `adid`、`responseId` 和 `actualStayTime`。业务名是广告位来源，代码按每次下发的 `id` 发起请求。
4. 视频任务请求 `GET /ting/incentive`，使用 `sourceName=secondaryPage_big_duration_task`，从响应读取 `adid`、`responseId` 与视频时长；等待时长取视频时长加 5 秒与 35 秒中的较大值。
5. `POST /incentive/ting/rewardDuration` 逐项领取时使用 `type=14`、`rewardDurType=21`、任务 `index`、广告 `adId` 与 `responseId`。四项完成后使用 `rewardDurType=22` 领取合计 `7200` 秒。签名为 `MD5(ticket & deviceId & type & duration & requestId & salt)`，`ticket` 的业务属性为 `b=incentives&s=time_reward&u=<uid>`。`salt` 由 [xmly_browse_reward.dart](../lib/api/xmly_browse_reward.dart) 维护。

正式版实机已完成两项浏览、两项视频，最终响应确认获得 120 分钟。空广告字段的领取请求曾返回 `failCode=10049`；带本次广告响应的 `adId` 与 `responseId` 后，视频任务领取成功。再次领取返回今日任务完成状态。

## 极速版调用链

1. `GET /lite-earn/ting/welfare/queryVipDurationTask` 下发 `tierList`。样本包含四档增量：`600`、`1800`、`3600`、`86400` 秒；`status=0` 待领取，`status=1` 已领取。
2. `POST /subapp/common` 使用 `name=sub_freetime_inspire_video` 与 `extInfo={"sourceName":"VIP_DURATION"}` 请求广告。该路径按业务名取广告，领取流程没有固定 `slotId`。响应根部的 `responseId` 与 `data[].adid` 进入领取请求；当前选择 `adtype=10026` 的广告，等待 35 秒。
3. `POST /lite-earn/ting/welfare/rewardDuration` 携带 `requestId`、`uid`、`ts`、`signature`、`ticket`、`adId`、`adResponseId`、`isUnisdk=false`、`isSecondPhaseCompleted=false`。签名为 `MD5(requestId & uid & ts & isSecondPhaseCompleted & salt)`，`ticket` 的业务属性为 `b=lite&s=lite_time_reward&u=<uid>`；公式与字段实现见 [xmly_rewards.dart](../lib/api/xmly_rewards.dart)。

极速版 APK 的广告达标回调还提供 `ecpm` 与 `verifyStr`。当前实机的 `adtype=10026` 路径携带本次广告 ID、响应 ID 与上述标记即可成功领取。四档领取后，账号余额从 600 秒增至 93000 秒，增量为 92400 秒，与四档合计一致。

## 代码入口与后续分析

- [xmly_client.dart](../lib/api/xmly_client.dart)：接口范围、两个客户端的请求头与设备 Cookie。
- [xmly_crypto.dart](../lib/api/xmly_crypto.dart)：正式版与极速版的 `ticket` 身份及版本。
- [account_service.dart](../lib/services/account_service.dart)：每账号正式版设备 ID 的安全存储与五步领取流程。
- [app_runtime.dart](../lib/services/app_runtime.dart)：自动领取开关与定期执行。
- [account_page.dart](../lib/pages/account_page.dart)：手动入口、设备设置与完成提示。

后续遇到任务或广告参数调整时，先记录当前正式版与极速版版本、任务下发响应及广告响应，再按本页调用链对照业务名和字段。若极速版广告列表仅下发 UniSDK 素材，继续追踪广告达标回调中的 `verifyStr` 与 `ecpm` 来源，再接入对应领取路径。发布版号、安装包类型和 OpenList 目录以当次发布记录为准。

## 设备身份分析记录

本节记录 2026-11-23（PST）本机 APK 静态分析与手机请求对照；手机当地显示 2026-11-24。样本为正式版 `9.5.31.3`、极速版 `3.5.15.3`。设备值、账号凭证与完整 Cookie 均留在手机及本地安全存储；文档仅记录形态和调用关系。

### 正式版：Xuid 生成与使用

1. `XuidManager.init` 的 `DefaultOptionProvider` 向 Xuid SDK 提供旧设备值、OAID、Android ID。`DeviceTokenUtil.getDeviceToken` 优先读取 Xuid provider 的值，再回到旧设备值。旧设备值由 `DeviceTokenUtil.getOldDeviceToken` 调用 `EncryptUtil.d(context)`，最终进入原生方法 `aCKmvpvrzC`。相关类为 `com.ximalaya.ting.android.host.manager.XuidManager`、`com.ximalaya.ting.android.encryptservice.DeviceTokenUtil` 与 `EncryptUtil`。
2. Xuid SDK 的 `OooO00o.OooO00o.OooO00o.b.f()` 依次选 Android ID、MAC、IMEI。选中硬件来源时，将 `brand + model + 来源值` 计算为 MD5，连同来源标记 `A`、`M` 或 `I` 交给 `NativeLib.dxbPWlbbFU`。当这些来源皆为空时，SDK 生成随机 UUID，移除连字符后以标记 `U` 交给同一原生方法。
3. `libnativelib.so` 的原生路径生成 35 字符 Xuid：3 字符前缀与 32 字符编码主体；主体含 16 字节来源数据及 8 字节校验数据。原生解析入口同时处理 16 字节原始值、32 字符十六进制值、35 字符 Xuid、36 字符 UUID。SDK 的 `OooO00o.OooO00o.OooO00o.OooO0oO.h` 经 `xUid_SpUtils` 以 `k_xuid` 保存结果，并读取缓存用于启动阶段。以上属于 APK 静态证据，原生编码细节仍可继续追踪。
4. [Android 官方文档](https://developer.android.com/reference/android/provider/Settings.Secure#ANDROID_ID)说明：Android 8 起 Android ID 随应用签名身份、用户与设备划分。XMPlus 进程读出的 Android ID 与正式版进程的来源条件各异；仅用 XMPlus 的 Android ID 计算一条 UUID，无法等同正式版 Xuid 生成链。

手机对照：新生成的 UUID 用于正式版请求时，`replaceConfig`、`currentDuration`、`durationConfig` 返回 `ret=0`，`recAlbumInfo` 连续两次返回 `ret=-1` 与 `Internal Server Error`；恢复原正式版设备值后，同账号 `recAlbumInfo` 返回 `ret=0`，主任务 `status=3`，四项任务均已完成。当天任务领取阶段已结束，这轮对照验证的是任务下发阶段。原工作区代码把 MD5 字节的 UUID 版本位设成 `3`，其文档先前写作 v4；实机结果支持继续使用已验证的正式版设备值设置入口。`1.2.7+24` Debug 包安装后，账号的正式版设备设置仍显示已保存的 36 字符值；此处仅记录长度，设备值留在手机安全存储。

### 极速版：当前证据边界

极速版 APK 多处从 `com.ximalaya.ting.android.host.util.common.e.getDeviceToken(context)` 取设备值，随后填入 `deviceId`、`device_id` 等请求字段。已检查基础 APK 的 DEX 类定义，该类定义缺席；包内 `classes.jar` 仅含 Hermes 的 `BuildConfig.class`。极速版 `libencrypt.so` 当前可见的导出符号主要是引导入口，静态材料尚未给出设备值的完整生成、保存链。

极速版自身 `netLog-main.txt` 的 Cookie 中可见 36 字符 UUID 形态，版本位为 `3`。此项属于手机运行记录，能确认实际请求的设备值形态，尚未证明其种子来源。XMPlus 的短信登录目前生成 UUID v4，导入 Cookie 时沿用其中设备值；已保存的极速版账号设备值在四档听时领取中完成实机验证。现阶段继续沿用账号保存的设备值。

### 后续定位顺序

正式版继续追踪 Xuid 注册、旧设备值迁移与账号关联，再用任务下发结果确认生成规则。极速版继续定位缺席的 `getDeviceToken` 类及其原生调用，核实种子与持久化位置。每次新增证据均记录 APK 版本、观察入口、字段形态、服务端结果和结论层级；实现仅采用实机验证过的设备身份路径。
