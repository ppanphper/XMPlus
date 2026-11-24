// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:crypto/crypto.dart';
import 'package:synchronized/synchronized.dart';
import 'package:uuid/uuid.dart';

import '../models/xmly_models.dart';
import '../services/android_platform.dart';
import '../services/ios_platform.dart';
import 'xmly_client.dart';
import 'xmly_crypto.dart';
import "../services/app_log.dart";

class XmlyRewards {
  XmlyRewards(this.client, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now {
    AppLog.instance.trace("lib/api/xmly_rewards.dart::XmlyRewards.new");
  }
  final XmlyClient client;
  final DateTime Function() _clock;
  final _lock = Lock();

  static const _salt = '0ab3443b71834b33be675af744d76ef0aaa74cd2b60c4b67';
  static const _path = '/lite-earn/ting/welfare/';

  String _uid() {
    AppLog.instance.trace("lib/api/xmly_rewards.dart::XmlyRewards._uid");

    final credentials = client.credentials;
    if (!client.accountAvailable || credentials == null) {
      throw XmlyException('login_expired', '领取或查询听时需要有效的登录态');
    }
    if (!RegExp(r'^[1-9][0-9]*$').hasMatch(credentials.uid)) {
      throw XmlyException('auth_required', '登录态缺少有效账号标识');
    }
    return credentials.uid;
  }

  static Map<String, dynamic> _result(
    Map<String, dynamic> response, {
    bool mutation = false,
  }) {
    AppLog.instance.trace("lib/api/xmly_rewards.dart::XmlyRewards._result");

    final data = response['data'];
    if (data is! Map<String, dynamic> || data['success'] is! bool) {
      throw XmlyException(
        mutation ? 'reward_result_unknown' : 'reward_task_invalid',
        '福利响应缺少明确结果',
        definitive: !mutation,
      );
    }
    if (data['success'] != true) {
      throw XmlyException(
        mutation ? 'reward_rejected' : 'reward_task_rejected',
        '${data['msg'] ?? data['toast'] ?? data['code'] ?? (mutation ? '服务端未发放听时' : '听时任务查询未成功')}',
        definitive: true,
      );
    }
    return data;
  }

  Future<Map<String, dynamic>> tasks() async {
    AppLog.instance.trace("lib/api/xmly_rewards.dart::XmlyRewards.tasks");

    _uid();
    final response = await client.request(
      'GET',
      XmlyClient.welfare,
      '${_path}queryVipDurationTask/ts-${_clock().millisecondsSinceEpoch}',
    );
    return {'data': _result(response)};
  }

  Map<String, dynamic> _payload(Map<String, dynamic> value) {
    AppLog.instance.trace("lib/api/xmly_rewards.dart::XmlyRewards._payload");

    final fields = <String, dynamic>{};
    for (final key in [
      'adId',
      'adResponseId',
      'isUnisdk',
      'ecpm',
      'verifyStr',
      'isSecondPhaseCompleted',
      'sourceName',
    ]) {
      if (value.containsKey(key) &&
          (key == 'sourceName' || value[key] != null) &&
          (key != 'verifyStr' ||
              (value[key] != null &&
                  value[key] != '' &&
                  value[key] != false))) {
        final item = value[key];
        if (item != null && item is! String && item is! num && item is! bool) {
          throw ArgumentError('福利请求字段格式无效');
        }
        if (item is String && item.length > 8192)
          throw ArgumentError('福利请求字段过长');
        if (item is num && !item.isFinite) throw ArgumentError('福利请求字段格式无效');
        fields[key] = item;
      }
    }
    final uid = _uid();
    final request = const Uuid().v4();
    final timestamp = _clock().millisecondsSinceEpoch;
    final parts = [request, uid, '$timestamp'];
    if (fields['isSecondPhaseCompleted'] != null) {
      parts.add('${fields['isSecondPhaseCompleted']}');
    }
    final signature = md5
        .convert(utf8.encode('${parts.join('&')}&$_salt'))
        .toString();
    return {
      ...fields,
      'requestId': request,
      'uid': int.parse(uid),
      'ts': timestamp,
      'signature': signature,
      'ticket': XmlyCrypto.freshTicket(
        client.credentials!,
        attributes: 'b=lite&s=lite_time_reward&u=$uid',
        liteAppVersion: '3.5.15.3',
      ),
    };
  }

  Future<Map<String, dynamic>> claim(Map<String, dynamic> value) {
    AppLog.instance.trace("lib/api/xmly_rewards.dart::XmlyRewards.claim");
    return _lock.synchronized(() {
      AppLog.instance.trace(
        "lib/api/xmly_rewards.dart::XmlyRewards.claim.closure#1",
      );
      return client.withBalanceChange(() {
        AppLog.instance.trace(
          "lib/api/xmly_rewards.dart::XmlyRewards.claim.closure#1.closure#1",
        );
        return _claim(value);
      });
    });
  }

  Future<Map<String, dynamic>> _claim(Map<String, dynamic> value) async {
    AppLog.instance.trace("lib/api/xmly_rewards.dart::XmlyRewards._claim");

    // The official client queries tasks, completes an ad/browse task, and only
    // then sends the SDK callback fields. An empty payload is not a reward.
    final taskData = (await tasks())['data'] as Map<String, dynamic>;
    final tiers = taskData['tierList'];
    if (taskData['showTask'] == false || (tiers is List && tiers.isEmpty)) {
      throw const XmlyException(
        'reward_unavailable',
        '当前没有可领取的听时任务',
        definitive: true,
      );
    }
    if (tiers is! List ||
        tiers.any((tier) {
          AppLog.instance.trace(
            'lib/api/xmly_rewards.dart::XmlyRewards._claim.closure#1',
          );
          return tier is! Map || !const [0, 1].contains(tier['status']);
        })) {
      throw const XmlyException(
        'reward_task_invalid',
        '暂时无法识别听时任务',
        definitive: true,
      );
    }
    if (tiers.every((tier) {
      AppLog.instance.trace(
        'lib/api/xmly_rewards.dart::XmlyRewards._claim.closure#2',
      );
      return tier['status'] == 1;
    })) {
      throw const XmlyException(
        'reward_completed',
        '今天的听时任务已完成',
        definitive: true,
      );
    }
    final hasCompletion = const ['adId', 'adResponseId', 'verifyStr'].any((
      key,
    ) {
      AppLog.instance.trace(
        'lib/api/xmly_rewards.dart::XmlyRewards._claim.closure#3',
      );
      return value[key] != null &&
          value[key] != '' &&
          value[key] != false &&
          value[key] != 0;
    });
    if (!hasCompletion) {
      throw const XmlyException(
        'reward_task_required',
        '请先完成官方广告或浏览任务',
        definitive: true,
      );
    }
    final payload = _payload(value);
    client.invalidateQuota();
    try {
      // A mutation is sent once. Neither transient errors nor an unrecognized
      // response authorize a retry or a second reward.
      final response = await client.request(
        'POST',
        XmlyClient.welfare,
        '${_path}rewardDuration/ts-${payload['ts']}',
        data: payload,
      );
      return {'data': _result(response, mutation: true)};
    } catch (error, stack) {
      if (error is XmlyException && error.definitive) rethrow;
      final failure = const XmlyException('reward_result_unknown', '领取请求结果未知');
      AppLog.instance.linkError(failure, error);
      AppLog.instance.write(
        AppLogLevel.warning,
        'rewards',
        'Reward response unknown',
        data: {'stage': 'claim_response'},
        error: error,
        stackTrace: stack,
      );
      Error.throwWithStackTrace(failure, stack);
    }
  }

  Future<Quota> claimAndRefresh(Map<String, dynamic> value) async {
    AppLog.instance.trace(
      'lib/api/xmly_rewards.dart::XmlyRewards.claimAndRefresh',
    );
    await claim(value);
    try {
      return await client.queryQuota();
    } catch (error, stack) {
      // The reward is confirmed even if the following read fails. Retrying
      // this operation means querying the balance, never issuing again.
      final failure = const XmlyException(
        'reward_claimed_quota_failed',
        '听时已领取，余额刷新失败',
        definitive: true,
      );
      AppLog.instance.linkError(failure, error);
      AppLog.instance.write(
        AppLogLevel.warning,
        'rewards',
        'Reward confirmed; balance refresh failed',
        data: {'stage': 'quota_after_claim'},
        error: error,
        stackTrace: stack,
      );
      Error.throwWithStackTrace(failure, stack);
    }
  }

  Future<Map<String, dynamic>> _advertisement() async {
    AppLog.instance.trace(
      'lib/api/xmly_rewards.dart::XmlyRewards._advertisement',
    );
    final quota = await client.queryQuota();
    final account = client.credentials!;
    final response = await client.request(
      'POST',
      XmlyClient.advertising,
      '/subapp/common',
      data: {
        'userAgent': Platform.isIOS
            ? await IosPlatform.rewardUserAgent()
            : await AndroidPlatform.rewardUserAgent(),
        'version': '3.5.15',
        'network': 'wifi',
        'localDuration': '${quota.remainingSeconds}',
        'uid': account.uid,
        'adxdevice': account.deviceId,
        'appid': '1463',
        'name': 'sub_freetime_inspire_video',
        'extInfo': '{"sourceName":"VIP_DURATION"}',
        'xt': '${_clock().millisecondsSinceEpoch}',
        'device': 'android',
      },
    );
    final ads = response['data'];
    final ad = ads is List
        ? ads.map(xmlyMap).where((item) {
            AppLog.instance.trace(
              'lib/api/xmly_rewards.dart::XmlyRewards._advertisement.closure#1',
            );
            return item['adtype'] == 10026;
          }).firstOrNull
        : null;
    final adId = ad?['adid'];
    final responseId = response['responseId'];
    if (adId == null || responseId == null) {
      throw const XmlyException('reward_ad_unavailable', '当前暂无极速版领时广告');
    }
    return {
      'adId': adId,
      'adResponseId': responseId,
      'isUnisdk': false,
      'isSecondPhaseCompleted': false,
    };
  }

  Future<Quota> claimNext({bool Function()? shouldContinue}) async {
    AppLog.instance.trace('lib/api/xmly_rewards.dart::XmlyRewards.claimNext');
    final data = (await tasks())['data'] as Map<String, dynamic>;
    final tiers = data['tierList'];
    if (data['showTask'] == false || tiers is! List || tiers.isEmpty) {
      throw const XmlyException('reward_unavailable', '当前暂无极速版领时任务');
    }
    if (tiers.every((tier) {
      AppLog.instance.trace(
        'lib/api/xmly_rewards.dart::XmlyRewards.claimNext.closure#1',
      );
      return tier is Map && tier['status'] == 1;
    })) {
      throw const XmlyException('reward_completed', '今天的听时任务已完成');
    }
    final advertisement = await _advertisement();
    await Future<void>.delayed(const Duration(seconds: 35));
    if (shouldContinue?.call() == false) return client.queryQuota();
    return claimAndRefresh(advertisement);
  }
}
