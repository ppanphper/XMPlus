import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import '../models/xmly_models.dart';
import '../services/android_platform.dart';
import '../services/app_log.dart';
import 'xmly_client.dart';
import 'xmly_crypto.dart';

class OfficialListeningBalance {
  OfficialListeningBalance.fromApi(Map<String, dynamic> data)
    : seconds = (data['balance'] as num).toInt(),
      addedSeconds = (data['duration'] as num? ?? 0).toInt(),
      freeUntil = (data['freeListenDeadline'] as num? ?? 0).toInt() {
    AppLog.instance.trace(
      'lib/api/xmly_browse_reward.dart::OfficialListeningBalance.fromApi',
    );
  }

  final int seconds;
  final int addedSeconds;
  final int freeUntil;

  bool get allDay {
    AppLog.instance.trace(
      'lib/api/xmly_browse_reward.dart::OfficialListeningBalance.allDay.get',
    );
    return freeUntil > DateTime.now().millisecondsSinceEpoch;
  }
}

class BrowseRewardOffer {
  BrowseRewardOffer({required this.stay, required this.fields}) {
    AppLog.instance.trace(
      'lib/api/xmly_browse_reward.dart::BrowseRewardOffer.new',
    );
  }

  final Duration stay;
  final Map<String, dynamic> fields;
}

class XmlyBrowseReward {
  XmlyBrowseReward(this.client) {
    AppLog.instance.trace(
      'lib/api/xmly_browse_reward.dart::XmlyBrowseReward.new',
    );
  }

  final XmlyClient client;
  static const _salt = '0ab3443b71834b33be675af744d76ef0aaa74cd2b60c4b67';
  static const _path = '/incentive/ting/';
  String get _deviceId {
    AppLog.instance.trace(
      'lib/api/xmly_browse_reward.dart::XmlyBrowseReward._deviceId.get',
    );
    return client.credentials!.deviceId;
  }

  Map<String, dynamic> _data(
    Map<String, dynamic> response,
    String stage, {
    bool requireSuccess = false,
  }) {
    AppLog.instance.trace(
      'lib/api/xmly_browse_reward.dart::XmlyBrowseReward._data',
    );
    final data = response['data'];
    AppLog.instance.write(
      AppLogLevel.info,
      'rewards',
      'Official listening response',
      data: {
        'stage': stage,
        'ret': response['ret'],
        'dataType': data.runtimeType.toString(),
        if (data is Map) 'fields': data.keys.toList(),
        if (data is Map) 'success': data['success'],
        if (data is Map) 'failCode': data['failCode'],
        if (data is Map) 'toast': data['toast'],
      },
    );
    if (data is! Map<String, dynamic>) {
      throw XmlyException('reward_response_invalid', '领时响应格式待适配（$stage）');
    }
    if (requireSuccess && data['success'] != true) {
      throw XmlyException(
        'reward_rejected',
        '${data['toast'] ?? data['msg'] ?? '当前领时请求未成功'}',
        definitive: true,
      );
    }
    return data;
  }

  Future<Map<String, dynamic>> _context() async {
    AppLog.instance.trace(
      'lib/api/xmly_browse_reward.dart::XmlyBrowseReward._context',
    );
    final account = client.credentials!;
    final response = await client.request(
      'POST',
      XmlyClient.mobile,
      '/mobile-album/album/replaceConfig',
      form: true,
      data: {
        'uid': account.uid,
        'deviceId': _deviceId,
        'freeListenTabStyle': '0',
        'initialStart': 'true',
      },
    );
    final raw = _data(response, 'replaceConfig')['albumSubscript'];
    final config = raw is String ? xmlyMap(jsonDecode(raw)) : xmlyMap(raw);
    final scene = '${config['sceneInfo'] ?? ''}'.split('_');
    final context = {
      if (scene.length >= 2) 'sceneId': int.parse(scene[1]),
      if (scene.length >= 2) 'groupId': int.parse(scene[0]),
      'ext': config['freeListenExt'] ?? '',
      'newFreeCrowd': config['newFreeCrowd'] ?? '',
    };
    AppLog.instance.write(
      AppLogLevel.info,
      'rewards',
      'Official listening context',
      data: {
        'configFields': config.keys.toList(),
        'sceneId': context['sceneId'],
        'groupId': context['groupId'],
        'extPresent': '${context['ext']}'.isNotEmpty,
        'newFreeCrowd': context['newFreeCrowd'],
      },
    );
    return context;
  }

  Future<OfficialListeningBalance> queryBalance({
    Map<String, dynamic>? context,
  }) async {
    AppLog.instance.trace(
      'lib/api/xmly_browse_reward.dart::XmlyBrowseReward.queryBalance',
    );
    final fields = context ?? await _context();
    final response = await client.request(
      'GET',
      XmlyClient.advertising,
      '${_path}currentDuration/ts-${DateTime.now().millisecondsSinceEpoch}',
      query: {
        'requestId': const Uuid().v4(),
        'localDuration': 0,
        if (fields.containsKey('sceneId')) 'sceneId': fields['sceneId'],
        if (fields.containsKey('groupId')) 'groupId': fields['groupId'],
        'ext': fields['ext'],
      },
    );
    return OfficialListeningBalance.fromApi(
      _data(response, 'currentDuration', requireSuccess: true),
    );
  }

  Map<String, dynamic> _payload(Map<String, dynamic> fields) {
    AppLog.instance.trace(
      'lib/api/xmly_browse_reward.dart::XmlyBrowseReward._payload',
    );
    final account = client.credentials!;
    final requestId = const Uuid().v4();
    final type = fields['type'];
    final duration = type == 5 ? 0 : fields['duration'];
    final ticket = XmlyCrypto.freshTicket(
      Credentials(token: account.token, deviceId: _deviceId),
      mainApp: true,
      attributes: 'b=incentives&s=time_reward&u=${account.uid}',
    );
    final signature = md5.convert(
      utf8.encode('$ticket&$_deviceId&$type&$duration&$requestId&$_salt'),
    );
    return {
      'adId': 0,
      'responseId': '0',
      'fallbackReq': '0',
      'rewardDurType': 0,
      'rewardStage': 0,
      'secondPhaseType': 0,
      'verifyStr': '',
      'isUnisdk': false,
      'startTime': 0,
      'endTime': 0,
      'retry': 0,
      'autoReward': false,
      ...fields,
      'requestId': requestId,
      'duration': duration,
      'ts': DateTime.now().millisecondsSinceEpoch,
      'ticket': ticket,
      'signature': signature.toString(),
    };
  }

  Future<BrowseRewardOffer> load() async {
    AppLog.instance.trace(
      'lib/api/xmly_browse_reward.dart::XmlyBrowseReward.load',
    );
    final context = await _context();
    final balance = await queryBalance(context: context);
    final configResponse = await client.request(
      'GET',
      XmlyClient.advertising,
      '${_path}durationConfig/ts-${DateTime.now().millisecondsSinceEpoch}',
      query: {
        if (context.containsKey('sceneId')) 'sceneId': context['sceneId'],
        if (context.containsKey('groupId')) 'groupId': context['groupId'],
        'ext': context['ext'],
        'newFreeCrowd': context['newFreeCrowd'],
      },
    );
    final config = _data(configResponse, 'durationConfig');
    final taskResponse = await client.request(
      'GET',
      XmlyClient.advertising,
      '${_path}recAlbumInfo/ts-${DateTime.now().millisecondsSinceEpoch}',
      query: {
        'pageNum': '0',
        if (context.containsKey('sceneId')) 'sceneId': context['sceneId'],
        if (context.containsKey('groupId')) 'groupId': context['groupId'],
        'sourceName': 'myAsset',
        'rnPage': 'false',
        'ext': context['ext'],
      },
    );
    final taskData = _data(taskResponse, 'recAlbumInfo');
    final task = xmlyMap(taskData['bigDurationTask']);
    final rawTasks = task['adTasks'];
    final tasks = rawTasks is List
        ? rawTasks.map(xmlyMap).toList()
        : <Map<String, dynamic>>[];
    final pending = [
      for (final item in tasks)
        if (item['status'] != 1) item,
    ];
    AppLog.instance.write(
      AppLogLevel.info,
      'rewards',
      'Official task delivery',
      data: {
        'status': task['status'],
        'giftDuration': task['giftDuration'],
        'taskCount': tasks.length,
        'completedCount': task['completedCount'],
        'pendingTypes': [for (final item in pending) item['taskType']],
      },
    );
    if (task['status'] == 2 && pending.isEmpty) {
      return BrowseRewardOffer(
        stay: Duration.zero,
        fields: {
          ...context,
          'localDuration': balance.seconds,
          'adViewDuration': config['adViewDuration'] ?? 0,
          'type': 14,
          'duration': task['giftDuration'] ?? 0,
          'rewardDurType': 22,
          'sourceName': 'secondaryPage_big_duration_task',
        },
      );
    }
    if (task['status'] == 3 && pending.isEmpty) {
      throw const XmlyException(
        'reward_completed',
        '今日听时任务已完成',
        definitive: true,
      );
    }
    final browse = [
      for (final item in pending)
        if (item['taskType'] == 2) item,
    ];
    final userAgent = await AndroidPlatform.rewardUserAgent();
    if (browse.isEmpty) {
      final video = [
        for (final item in pending)
          if (item['taskType'] == 3) item,
      ];
      if (video.isEmpty) {
        throw const XmlyException(
          'reward_unavailable',
          '当前暂无听时任务',
          definitive: true,
        );
      }
      final videoResponse = await client.request(
        'GET',
        XmlyClient.advertising,
        '/ting/incentive/ts-${DateTime.now().millisecondsSinceEpoch}',
        query: {
          'appid': '0',
          'duringPlay': 'false',
          'freeListenType': '0',
          'groupId': context['groupId'],
          'isDisplayedInScreen': 'true',
          'lastShowTime': '0',
          'localDuration': balance.seconds,
          'name': 'incentive_duration',
          'pageMode': '0',
          'positionId': '87',
          'sceneId': context['sceneId'],
          'sourceName': 'secondaryPage_big_duration_task',
          'uniPreload': '0',
          'ext': context['ext'],
          'uid': client.credentials!.uid,
          'userAgent': userAgent,
          'xt': '${DateTime.now().millisecondsSinceEpoch}',
        },
      );
      final videoAds = videoResponse['data'];
      final videoAd = videoAds is List && videoAds.isNotEmpty
          ? xmlyMap(videoAds.first)
          : <String, dynamic>{};
      final videoId = videoAd['adid'];
      final videoResponseId = videoResponse['responseId'];
      if (videoId == null || videoResponseId == null) {
        throw const XmlyException('reward_ad_unavailable', '当前暂无视频任务广告');
      }
      final videoSeconds = int.tryParse('${videoAd['videoDuration']}') ?? 0;
      AppLog.instance.write(
        AppLogLevel.info,
        'rewards',
        'Official video response',
        data: {
          'adCount': videoAds is List ? videoAds.length : 0,
          'adType': videoAd['adtype'],
          'videoSeconds': videoSeconds,
        },
      );
      return BrowseRewardOffer(
        stay: Duration(seconds: videoSeconds > 30 ? videoSeconds + 5 : 35),
        fields: {
          ...context,
          'localDuration': balance.seconds,
          'adViewDuration': config['adViewDuration'] ?? 0,
          'type': 14,
          'duration': 0,
          'rewardDurType': 21,
          'index': video.first['index'],
          'adId': videoId,
          'responseId': '$videoResponseId',
          'sourceName': 'secondaryPage_big_duration_task',
        },
      );
    }
    final initResponse = await client.request(
      'POST',
      XmlyClient.advertising,
      '/adx/init',
      data: {
        'appid': '0',
        'appVersion': '9.5.31',
        'sdkVersion': '1.2.15',
        'sdkJarVersion': '12044',
        'templateVersion': '0',
        'sdks': '1,2,4,5,6,3',
        'userAgent': userAgent,
        'uid': client.credentials!.uid,
        'xt': '${DateTime.now().millisecondsSinceEpoch}',
      },
    );
    final rawSlots = initResponse['slots'];
    final matchingSlots = rawSlots is List
        ? [
            for (final raw in rawSlots)
              if (xmlyMap(raw)['positionName'] == 'inspire_video_wake_end')
                xmlyMap(raw),
          ]
        : <Map<String, dynamic>>[];
    final slot = matchingSlots.firstOrNull;
    final slotId = slot?['id'];
    if (slotId == null) {
      throw const XmlyException('reward_ad_unavailable', '当前暂无浏览任务广告位');
    }
    AppLog.instance.write(
      AppLogLevel.info,
      'rewards',
      'Official ad slot',
      data: {'id': slotId, 'positionId': slot?['positionId']},
    );
    final adResponse = await client.request(
      'POST',
      XmlyClient.advertising,
      '/adx/ad',
      query: {'slotId': '$slotId'},
      data: {
        'appid': '0',
        'appVersion': '9.5.31',
        'sdkVersion': '1.2.15',
        'sdkJarVersion': '12044',
        'templateVersion': '0',
        'sdks': '1,2,4,5,6,3',
        'slotIds': '$slotId',
        'userAgent': userAgent,
        'sourceName': 'secondaryPage_big_duration_task',
        if (context.containsKey('sceneId')) 'sceneId': '${context['sceneId']}',
        if (context.containsKey('groupId')) 'groupId': '${context['groupId']}',
        'uid': client.credentials!.uid,
        'xt': '${DateTime.now().millisecondsSinceEpoch}',
      },
    );
    final slots = adResponse['slotAds'];
    final firstSlot = slots is List && slots.isNotEmpty
        ? xmlyMap(slots.first)
        : <String, dynamic>{};
    final ads = firstSlot['ads'];
    if (ads is! List || ads.isEmpty) {
      throw const XmlyException('reward_ad_unavailable', '当前暂无浏览任务广告');
    }
    final ad = xmlyMap(ads.first);
    final adId = ad['adid'] ?? ad['adId'];
    final responseId = ad['responseId'] ?? adResponse['responseId'];
    AppLog.instance.write(
      AppLogLevel.info,
      'rewards',
      'Official browse selection',
      data: {
        'adCount': ads.length,
        'adType': ad['adtype'],
        'adIdPresent': adId != null,
        'responseIdPresent': responseId != null,
        'taskIndex': browse.first['index'],
        'tipStay': ad['tipStayTime'],
        'actualStay': ad['actualStayTime'],
      },
    );
    if (adId == null || responseId == null) {
      throw const XmlyException('reward_ad_unavailable', '浏览任务广告参数待适配');
    }
    final stay = (ad['actualStayTime'] as num? ?? 10).toInt();
    return BrowseRewardOffer(
      stay: Duration(seconds: stay > 0 ? stay : 10),
      fields: {
        ...context,
        'localDuration': balance.seconds,
        'adViewDuration': config['adViewDuration'] ?? 0,
        'type': 14,
        'duration': 0,
        'rewardDurType': 21,
        'index': browse.first['index'],
        'adId': adId,
        'responseId': '$responseId',
        'sourceName': 'secondaryPage_big_duration_task',
        if (ad['positionName'] != null) 'positionName': ad['positionName'],
        if (taskData['quoteId'] != null) 'quoteId': taskData['quoteId'],
      },
    );
  }

  Future<OfficialListeningBalance> claim(BrowseRewardOffer offer) async {
    AppLog.instance.trace(
      'lib/api/xmly_browse_reward.dart::XmlyBrowseReward.claim',
    );
    final payload = _payload(offer.fields);
    final response = await client.request(
      'POST',
      XmlyClient.advertising,
      '${_path}rewardDuration/ts-${payload['ts']}',
      data: payload,
    );
    return OfficialListeningBalance.fromApi(
      _data(response, 'rewardDuration', requireSuccess: true),
    );
  }
}
