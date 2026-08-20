import 'dart:async';

import 'package:amplitude_flutter/amplitude.dart';
import 'package:amplitude_flutter/configuration.dart';
import 'package:amplitude_flutter/constants.dart';
import 'package:amplitude_flutter/events/base_event.dart';
import 'package:amplitude_flutter/events/event_options.dart';
import 'package:amplitude_flutter/events/identify.dart';
import 'package:amplitude_flutter/events/revenue.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride, kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

/// Generates mocked MethodChannel.
/// ```
/// class MockMethodChannel extends Mock implements MethodChannel
/// ```
/// Learn more [here](https://github.com/dart-lang/mockito/blob/master/NULL_SAFETY_README.md).
@GenerateNiceMocks([MockSpec<MethodChannel>()])
import 'amplitude_test.mocks.dart';

class _MethodRecordingCodec implements MethodCodec {
  final MethodCodec _delegate = const StandardMethodCodec();
  final List<String> encodedMethods = [];

  @override
  ByteData encodeMethodCall(MethodCall methodCall) {
    encodedMethods.add(methodCall.method);
    return _delegate.encodeMethodCall(methodCall);
  }

  @override
  MethodCall decodeMethodCall(ByteData? methodCall) =>
      _delegate.decodeMethodCall(methodCall);

  @override
  dynamic decodeEnvelope(ByteData envelope) =>
      _delegate.decodeEnvelope(envelope);

  @override
  ByteData encodeSuccessEnvelope(Object? result) =>
      _delegate.encodeSuccessEnvelope(result);

  @override
  ByteData encodeErrorEnvelope({
    required String code,
    String? message,
    Object? details,
  }) =>
      _delegate.encodeErrorEnvelope(
        code: code,
        message: message,
        details: details,
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MockMethodChannel mockChannel;
  late Amplitude amplitude;

  MockMethodChannel buildMockChannel() {
    final channel = MockMethodChannel();
    when(channel.codec).thenReturn(const StandardMethodCodec());
    when(channel.invokeMethod<void>('awaitBuild', any))
        .thenAnswer((_) async {});
    return channel;
  }

  final testApiKey = 'test-api-key';
  final testUserId = 'test user id';
  final testDeviceId = 'test device id';
  final testProperty = 'property';
  final testValue = 'value';
  final testGroupType = 'group type';
  final testGroupName = 'group name';
  final testConfiguration = Configuration(apiKey: testApiKey);
  final testConfigurationMap = {
    'apiKey': testApiKey,
    'flushQueueSize': 30,
    'flushIntervalMillis': 30000,
    'instanceName': Constants.defaultInstanceName,
    'optOut': false,
    'logLevel': LogLevel.warn.name,
    'minIdLength': null,
    'partnerId': null,
    'flushMaxRetries': 5,
    'useBatch': false,
    'serverZone': ServerZone.us.name,
    'serverUrl': null,
    'minTimeBetweenSessionsMillis': 5 * 60 * 1000,
    'defaultTracking': {
      'sessions': true,
      'appLifecycles': false,
      'deepLinks': false,
      'attribution': true,
      'pageViews': true,
      'formInteractions': false,
      'fileDownloads': false,
    },
    'trackingOptions': {
      'ipAddress': true,
      'language': true,
      'platform': true,
      'region': true,
      'dma': true,
      'country': true,
      'city': true,
      'carrier': true,
      'deviceModel': true,
      'deviceManufacturer': true,
      'osVersion': true,
      'osName': true,
      'versionName': true,
      'adid': true,
      'appSetId': true,
      'deviceBrand': true,
      'latLag': true,
      'apiLevel': true,
      'idfv': true,
    },
    'enableCoppaControl': false,
    'flushEventsOnClose': true,
    'identifyBatchIntervalMillis': 30 * 1000,
    'migrateLegacyData': true,
    'locationListening': true,
    'useAdvertisingIdForDeviceId': false,
    'useAppSetIdForDeviceId': false,
    'appVersion': null,
    'deviceId': null,
    'cookieOptions': {
      'domain': '',
      'expiration': 365,
      'sameSite': 'Lax',
      'secure': false,
      'upgrade': true,
    },
    'identityStorage': 'cookie',
    'sessionTimeout': 30 * 60 * 1000,
    'userId': null,
    'transport': 'fetch',
    'fetchRemoteConfig': false,
    'autocapture': {
      'sessions': true,
      'attribution': {
        'initialEmptyValue': 'EMPTY',
        'resetSessionOnNewCampaign': false
      },
      'pageViews': false,
      'appLifecycles': false,
      'deepLinks': false,
      'screenViews': false,
      'formInteractions': false,
      'fileDownloads': false,
      'elementInteractions': false,
      'pageUrlEnrichment': false,
    },
    // This field doesn't belong to Configuration
    // Pass it for FlutterLibraryPlugin
    'library': '${Constants.packageName}/${Constants.packageVersion}'
  };
  late BaseEvent testEvent;
  final testEventMap = {
    'event_type': 'testEvent',
    'attempts': 0,
  };
  final testPrice = 3.99;
  final testQuantity = 3;
  final testProductId = 'com.company.productId';

  setUp(() async {
    mockChannel = buildMockChannel();
    when(mockChannel.invokeMethod<void>('init', any)).thenAnswer((_) async {});
    amplitude = Amplitude(testConfiguration, mockChannel);
    await amplitude.isBuilt;
    testEvent = BaseEvent('testEvent');
  });

  test('Should init and track call MethodChannel', () async {
    when(mockChannel.invokeMethod('track', any)).thenAnswer((_) async => null);
    await amplitude.track(testEvent);

    verify(mockChannel.invokeMethod('init', testConfigurationMap)).called(1);
    verify(mockChannel.invokeMethod('track', {
      'instanceName': Constants.defaultInstanceName,
      'event': testEventMap
    })).called(1);
  });

  test('Should track with event options calls MethodChannel', () async {
    when(mockChannel.invokeMethod('track', any)).thenAnswer((_) async => null);
    await amplitude.track(testEvent, EventOptions(userId: testUserId));

    final expectedEventMap = Map.from(testEventMap);
    expectedEventMap['user_id'] = testUserId;
    verify(mockChannel.invokeMethod('track', {
      'instanceName': Constants.defaultInstanceName,
      'event': expectedEventMap
    })).called(1);
  });

  test('Should identify calls MethodChannel', () async {
    when(mockChannel.invokeMethod('identify', any))
        .thenAnswer((_) async => null);

    final identify = Identify()..set(testProperty, testValue);
    await amplitude.identify(identify);

    final testIdentifyMap = Map.from(testEventMap);
    testIdentifyMap['event_type'] = Constants.identifyEvent;
    testIdentifyMap['user_properties'] = {
      '\$set': {testProperty: testValue}
    };
    verify(mockChannel.invokeMethod('identify', {
      'instanceName': Constants.defaultInstanceName,
      'event': testIdentifyMap
    })).called(1);
  });

  test('Should identify calls setUserId in MethodChannel', () async {
    when(mockChannel.invokeMethod('identify', any))
        .thenAnswer((_) async => null);
    when(mockChannel.invokeMethod('setUserId', any))
        .thenAnswer((_) async => null);

    final identify = Identify()..set(testProperty, testValue);
    await amplitude.identify(identify, EventOptions(userId: testUserId));

    final testIdentifyMap = Map.from(testEventMap);
    testIdentifyMap['user_id'] = testUserId;
    testIdentifyMap['event_type'] = Constants.identifyEvent;
    testIdentifyMap['user_properties'] = {
      '\$set': {testProperty: testValue}
    };
    verify(mockChannel.invokeMethod('setUserId', {
      'instanceName': Constants.defaultInstanceName,
      'properties': {'setUserId': testUserId}
    })).called(1);
    verify(mockChannel.invokeMethod('identify', {
      'instanceName': Constants.defaultInstanceName,
      'event': testIdentifyMap
    })).called(1);
  });

  test('Should identify calls setDeviceId in MethodChannel', () async {
    when(mockChannel.invokeMethod('identify', any))
        .thenAnswer((_) async => null);
    when(mockChannel.invokeMethod('setDeviceId', any))
        .thenAnswer((_) async => null);

    final identify = Identify()..set(testProperty, testValue);
    await amplitude.identify(identify, EventOptions(deviceId: testDeviceId));

    final testIdentifyMap = Map.from(testEventMap);
    testIdentifyMap['device_id'] = testDeviceId;
    testIdentifyMap['event_type'] = Constants.identifyEvent;
    testIdentifyMap['user_properties'] = {
      '\$set': {testProperty: testValue}
    };
    verify(mockChannel.invokeMethod('setDeviceId', {
      'instanceName': Constants.defaultInstanceName,
      'properties': {'setDeviceId': testDeviceId}
    })).called(1);
    verify(mockChannel.invokeMethod('identify', {
      'instanceName': Constants.defaultInstanceName,
      'event': testIdentifyMap
    })).called(1);
  });

  test('Should groupIdentify calls MethodChannel', () async {
    when(mockChannel.invokeMethod('groupIdentify', any))
        .thenAnswer((_) async => null);

    final groupIdentify = Identify()..set(testProperty, testValue);
    await amplitude.groupIdentify(testGroupType, testGroupName, groupIdentify);

    final testIdentifyMap = Map.from(testEventMap);
    testIdentifyMap['event_type'] = Constants.groupIdentifyEvent;
    testIdentifyMap['groups'] = {testGroupType: testGroupName};
    testIdentifyMap['group_properties'] = {
      '\$set': {testProperty: testValue}
    };
    verify(mockChannel.invokeMethod('groupIdentify', {
      'instanceName': Constants.defaultInstanceName,
      'event': testIdentifyMap
    })).called(1);
  });

  test('Should groupIdentify with event options calls MethodChannel', () async {
    when(mockChannel.invokeMethod('groupIdentify', any))
        .thenAnswer((_) async => null);

    final groupIdentify = Identify()..set(testProperty, testValue);
    await amplitude.groupIdentify(testGroupType, testGroupName, groupIdentify,
        EventOptions(userId: testUserId));

    final testIdentifyMap = Map.from(testEventMap);
    testIdentifyMap['event_type'] = Constants.groupIdentifyEvent;
    testIdentifyMap['user_id'] = testUserId;
    testIdentifyMap['groups'] = {testGroupType: testGroupName};
    testIdentifyMap['group_properties'] = {
      '\$set': {testProperty: testValue}
    };
    verify(mockChannel.invokeMethod('groupIdentify', {
      'instanceName': Constants.defaultInstanceName,
      'event': testIdentifyMap
    })).called(1);
  });

  test('Should setGroup calls MethodChannel', () async {
    when(mockChannel.invokeMethod('setGroup', any))
        .thenAnswer((_) async => null);

    await amplitude.setGroup(testGroupType, testGroupName);

    final testIdentifyMap = Map.from(testEventMap);
    testIdentifyMap['event_type'] = Constants.identifyEvent;
    testIdentifyMap['groups'] = {testGroupType: testGroupName};
    testIdentifyMap['user_properties'] = {
      '\$set': {testGroupType: testGroupName}
    };

    verify(mockChannel.invokeMethod('setGroup', {
      'instanceName': Constants.defaultInstanceName,
      'event': testIdentifyMap
    })).called(1);
  });

  test('Should setGroup with event options calls MethodChannel', () async {
    when(mockChannel.invokeMethod('setGroup', any))
        .thenAnswer((_) async => null);

    await amplitude.setGroup(
        testGroupType, testGroupName, EventOptions(userId: testUserId));

    final testIdentifyMap = Map.from(testEventMap);
    testIdentifyMap['event_type'] = Constants.identifyEvent;
    testIdentifyMap['groups'] = {testGroupType: testGroupName};
    testIdentifyMap['user_properties'] = {
      '\$set': {testGroupType: testGroupName}
    };
    testIdentifyMap['user_id'] = testUserId;

    verify(mockChannel.invokeMethod('setGroup', {
      'instanceName': Constants.defaultInstanceName,
      'event': testIdentifyMap
    })).called(1);
  });

  test('Should revenue calls MethodChannel', () async {
    when(mockChannel.invokeMethod('revenue', any))
        .thenAnswer((_) async => null);

    final revenue = Revenue()
      ..price = testPrice
      ..quantity = testQuantity
      ..productId = testProductId;
    await amplitude.revenue(revenue);

    final testRevenueMap = Map.from(testEventMap);
    testRevenueMap['event_type'] = Constants.revenueEvent;
    testRevenueMap['event_properties'] = {};
    testRevenueMap['event_properties'][RevenueConstants.revenuePrice] =
        testPrice;
    testRevenueMap['event_properties'][RevenueConstants.revenueQuantity] =
        testQuantity;
    testRevenueMap['event_properties'][RevenueConstants.revenueProductId] =
        testProductId;

    verify(mockChannel.invokeMethod('revenue', {
      'instanceName': Constants.defaultInstanceName,
      'event': testRevenueMap
    })).called(1);
  });

  test('Should revenue calls MethodChannel with event options', () async {
    when(mockChannel.invokeMethod('revenue', any))
        .thenAnswer((_) async => null);

    final revenue = Revenue()
      ..price = testPrice
      ..quantity = testQuantity
      ..productId = testProductId;
    await amplitude.revenue(revenue, EventOptions(userId: testUserId));

    final testRevenueMap = Map.from(testEventMap);
    testRevenueMap['user_id'] = testUserId;
    testRevenueMap['event_type'] = Constants.revenueEvent;
    testRevenueMap['event_properties'] = {};
    testRevenueMap['event_properties'][RevenueConstants.revenuePrice] =
        testPrice;
    testRevenueMap['event_properties'][RevenueConstants.revenueQuantity] =
        testQuantity;
    testRevenueMap['event_properties'][RevenueConstants.revenueProductId] =
        testProductId;

    verify(mockChannel.invokeMethod('revenue', {
      'instanceName': Constants.defaultInstanceName,
      'event': testRevenueMap
    })).called(1);
  });

  test('Should revenue calls MethodChannel with currency', () async {
    when(mockChannel.invokeMethod('revenue', any))
        .thenAnswer((_) async => null);

    final revenue = Revenue()
      ..price = testPrice
      ..quantity = testQuantity
      ..productId = testProductId
      ..revenueCurrency = 'USD';
    await amplitude.revenue(revenue);

    final testRevenueMap = Map.from(testEventMap);
    testRevenueMap['event_type'] = Constants.revenueEvent;
    testRevenueMap['event_properties'] = {};
    testRevenueMap['event_properties'][RevenueConstants.revenuePrice] =
        testPrice;
    testRevenueMap['event_properties'][RevenueConstants.revenueQuantity] =
        testQuantity;
    testRevenueMap['event_properties'][RevenueConstants.revenueProductId] =
        testProductId;
    testRevenueMap['event_properties'][RevenueConstants.revenueCurrency] =
        'USD'; // Event property currency

    verify(mockChannel.invokeMethod('revenue', {
      'instanceName': Constants.defaultInstanceName,
      'event': testRevenueMap
    })).called(1);
  });

  test('Should getUserId calls MethodChannel', () async {
    when(mockChannel.invokeMethod('getUserId', any))
        .thenAnswer((_) async => testUserId);

    final userId = await amplitude.getUserId();

    expect(userId, testUserId);
    verify(mockChannel.invokeMethod(
            'getUserId', {'instanceName': Constants.defaultInstanceName}))
        .called(1);
  });

  test('Should setUserId calls MethodChannel', () async {
    when(mockChannel.invokeMethod('setUserId', any))
        .thenAnswer((_) async => null);

    await amplitude.setUserId(testUserId);

    verify(mockChannel.invokeMethod('setUserId', {
      'instanceName': Constants.defaultInstanceName,
      'properties': {'setUserId': testUserId}
    })).called(1);
  });

  test('Should getDeviceId calls MethodChannel', () async {
    when(mockChannel.invokeMethod('getDeviceId', any))
        .thenAnswer((_) async => testDeviceId);

    final deviceId = await amplitude.getDeviceId();

    expect(deviceId, testDeviceId);
    verify(mockChannel.invokeMethod(
            'getDeviceId', {'instanceName': Constants.defaultInstanceName}))
        .called(1);
  });

  test('Should setDeviceId calls MethodChannel', () async {
    when(mockChannel.invokeMethod('setDeviceId', any))
        .thenAnswer((_) async => null);

    await amplitude.setDeviceId(testDeviceId);

    verify(mockChannel.invokeMethod('setDeviceId', {
      'instanceName': Constants.defaultInstanceName,
      'properties': {'setDeviceId': testDeviceId}
    })).called(1);
  });

  test('Should reset calls MethodChannel', () async {
    when(mockChannel.invokeMethod('reset', any)).thenAnswer((_) async => null);

    await amplitude.reset();

    verify(mockChannel.invokeMethod(
        'reset', {'instanceName': Constants.defaultInstanceName})).called(1);
  });

  test('Should flush calls MethodChannel', () async {
    when(mockChannel.invokeMethod('flush', any)).thenAnswer((_) async => null);

    await amplitude.flush();

    verify(mockChannel.invokeMethod(
        'flush', {'instanceName': Constants.defaultInstanceName})).called(1);
  });

  group('Android initialization', () {
    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    test('hands early calls to Android before awaiting native build', () async {
      mockChannel = buildMockChannel();
      final initCompleter = Completer<void>();
      final buildCompleter = Completer<void>();
      final dispatchOrder = <String>[];
      when(mockChannel.invokeMethod<void>('init', any))
          .thenAnswer((_) => initCompleter.future);
      when(mockChannel.invokeMethod<void>('track', any))
          .thenAnswer((_) async => dispatchOrder.add('track'));
      when(mockChannel.invokeMethod<void>('awaitBuild', any)).thenAnswer((_) {
        dispatchOrder.add('awaitBuild');
        return buildCompleter.future;
      });
      amplitude = Amplitude(testConfiguration, mockChannel);

      final trackFuture = amplitude.track(BaseEvent('early event'));
      var isBuiltCompleted = false;
      unawaited(amplitude.isBuilt.then((_) => isBuiltCompleted = true));

      verifyNever(mockChannel.invokeMethod<void>('track', any));

      initCompleter.complete();
      await untilCalled(mockChannel.invokeMethod<void>('awaitBuild', any));
      await trackFuture;

      expect(dispatchOrder, ['track', 'awaitBuild']);
      expect(isBuiltCompleted, isFalse);
      verify(mockChannel.invokeMethod<void>('track', {
        'instanceName': Constants.defaultInstanceName,
        'event': {'event_type': 'early event', 'attempts': 0}
      })).called(1);

      buildCompleter.complete();
      expect(await amplitude.isBuilt, isTrue);
    });

    test('preserves FIFO dispatch and snapshots mutable arguments', () async {
      mockChannel = buildMockChannel();
      final initCompleter = Completer<void>();
      final dispatchOrder = <String>[];
      final trackedArguments = <Map<dynamic, dynamic>>[];
      String? buildInstanceName;
      final configuration = Configuration(
        apiKey: testApiKey,
        instanceName: 'original-instance',
      );

      when(mockChannel.invokeMethod<void>('init', any))
          .thenAnswer((_) => initCompleter.future);
      when(mockChannel.invokeMethod<void>('track', any))
          .thenAnswer((invocation) async {
        final arguments =
            invocation.positionalArguments[1] as Map<dynamic, dynamic>;
        final event = arguments['event'] as Map<dynamic, dynamic>;
        dispatchOrder.add('track:${event['event_type']}');
        trackedArguments.add(arguments);
      });
      when(mockChannel.invokeMethod<void>('setUserId', any))
          .thenAnswer((_) async {
        dispatchOrder.add('setUserId');
      });
      when(mockChannel.invokeMethod<void>('awaitBuild', any))
          .thenAnswer((invocation) async {
        final arguments =
            invocation.positionalArguments[1] as Map<dynamic, dynamic>;
        buildInstanceName = arguments['instanceName'] as String;
      });
      amplitude = Amplitude(configuration, mockChannel);

      final nestedValues = <String>['before'];
      final firstEvent = BaseEvent(
        'first',
        eventProperties: {'nested': nestedValues},
      );
      final secondEvent = BaseEvent('second');
      final firstTrack = amplitude.track(firstEvent);
      final setUserId = amplitude.setUserId(testUserId);
      final secondTrack = amplitude.track(secondEvent);

      firstEvent.eventType = 'mutated';
      nestedValues[0] = 'after';
      secondEvent.eventType = 'also mutated';
      configuration.instanceName = 'mutated-instance';

      initCompleter.complete();
      await Future.wait<void>([firstTrack, setUserId, secondTrack]);

      expect(dispatchOrder, ['track:first', 'setUserId', 'track:second']);
      expect(
        trackedArguments.map((arguments) => arguments['instanceName']),
        everyElement('original-instance'),
      );
      expect(buildInstanceName, 'original-instance');
      final firstTrackedEvent =
          trackedArguments.first['event'] as Map<dynamic, dynamic>;
      final firstProperties =
          firstTrackedEvent['event_properties'] as Map<dynamic, dynamic>;
      expect(firstProperties['nested'], ['before']);
    });

    test('snapshots with the invoked method name for custom codecs', () async {
      mockChannel = buildMockChannel();
      final codec = _MethodRecordingCodec();
      final initCompleter = Completer<void>();
      when(mockChannel.codec).thenReturn(codec);
      when(mockChannel.invokeMethod<void>('init', any))
          .thenAnswer((_) => initCompleter.future);
      when(mockChannel.invokeMethod<void>('track', any))
          .thenAnswer((_) async {});
      amplitude = Amplitude(testConfiguration, mockChannel);

      final trackFuture = amplitude.track(BaseEvent('early event'));

      expect(codec.encodedMethods, ['track']);
      initCompleter.complete();
      await trackFuture;
    });

    test('registration failure rejects calls without dispatching', () async {
      mockChannel = buildMockChannel();
      final initCompleter = Completer<void>();
      final error = PlatformException(code: 'init-failed');
      when(mockChannel.invokeMethod<void>('init', any))
          .thenAnswer((_) => initCompleter.future);
      amplitude = Amplitude(testConfiguration, mockChannel);

      final trackFuture = amplitude.track(BaseEvent('never dispatched'));
      final trackExpectation = expectLater(trackFuture, throwsA(same(error)));
      initCompleter.completeError(error, StackTrace.current);

      expect(await amplitude.isBuilt, isFalse);
      await trackExpectation;
      await expectLater(amplitude.flush(), throwsA(same(error)));
      await expectLater(amplitude.getUserId(), throwsA(same(error)));
      verifyNever(mockChannel.invokeMethod<void>('track', any));
      verifyNever(mockChannel.invokeMethod<void>('flush', any));
      verifyNever(mockChannel.invokeMethod<String>('getUserId', any));
    });

    test('native build failure is reported after accepted calls dispatch',
        () async {
      mockChannel = buildMockChannel();
      final initCompleter = Completer<void>();
      final buildCompleter = Completer<void>();
      when(mockChannel.invokeMethod<void>('init', any))
          .thenAnswer((_) => initCompleter.future);
      when(mockChannel.invokeMethod<void>('awaitBuild', any))
          .thenAnswer((_) => buildCompleter.future);
      when(mockChannel.invokeMethod<void>('track', any))
          .thenAnswer((_) async {});
      amplitude = Amplitude(testConfiguration, mockChannel);

      final earlyTrack = amplitude.track(BaseEvent('accepted early'));
      initCompleter.complete();
      await untilCalled(mockChannel.invokeMethod<void>('awaitBuild', any));
      await earlyTrack;
      buildCompleter.completeError(
        PlatformException(code: 'amplitude_init_failed'),
        StackTrace.current,
      );

      expect(await amplitude.isBuilt, isFalse);
      await expectLater(
        amplitude.track(BaseEvent('rejected after failure')),
        throwsA(isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'amplitude_init_failed',
        )),
      );
      verify(mockChannel.invokeMethod<void>('track', any)).called(1);
    });

    test('dispatches directly once initialization has completed', () async {
      when(mockChannel.invokeMethod<void>('track', any))
          .thenAnswer((_) async {});

      final trackFuture = amplitude.track(BaseEvent('ready event'));

      verify(mockChannel.invokeMethod<void>('track', any)).called(1);
      await trackFuture;
    });

    test('keeps later calls dispatching after an operation fails', () async {
      final error = PlatformException(code: 'track-failed');
      when(mockChannel.invokeMethod<void>('track', any))
          .thenAnswer((invocation) {
        final arguments =
            invocation.positionalArguments[1] as Map<dynamic, dynamic>;
        final event = arguments['event'] as Map<dynamic, dynamic>;
        if (event['event_type'] == 'fails') {
          return Future<void>.error(error);
        }
        return Future<void>.value();
      });

      final failingTrack = amplitude.track(BaseEvent('fails'));
      final succeedingTrack = amplitude.track(BaseEvent('succeeds'));

      await expectLater(failingTrack, throwsA(same(error)));
      await succeedingTrack;
      verify(mockChannel.invokeMethod<void>('track', any)).called(2);
    });

    test('preserves identify identity order and completion behavior', () async {
      final dispatchOrder = <String>[];
      final allDispatched = Completer<void>();
      final userIdResponse = Completer<void>();
      final deviceIdResponse = Completer<void>();
      final identifyResponse = Completer<void>();

      when(mockChannel.invokeMethod<void>('setUserId', any)).thenAnswer((_) {
        dispatchOrder.add('setUserId');
        return userIdResponse.future;
      });
      when(mockChannel.invokeMethod<void>('setDeviceId', any)).thenAnswer((_) {
        dispatchOrder.add('setDeviceId');
        return deviceIdResponse.future;
      });
      when(mockChannel.invokeMethod<void>('identify', any)).thenAnswer((_) {
        dispatchOrder.add('identify');
        allDispatched.complete();
        return identifyResponse.future;
      });

      final identifyFuture = amplitude.identify(
        Identify()..set(testProperty, testValue),
        EventOptions(userId: testUserId, deviceId: testDeviceId),
      );
      final completed = Completer<void>();
      unawaited(identifyFuture.then((_) => completed.complete()));

      await allDispatched.future;
      expect(dispatchOrder, ['setUserId', 'setDeviceId', 'identify']);

      identifyResponse.complete();
      await identifyFuture;
      expect(completed.isCompleted, isTrue);
      expect(userIdResponse.isCompleted, isFalse);
      expect(deviceIdResponse.isCompleted, isFalse);

      userIdResponse.complete();
      deviceIdResponse.complete();
    });

    test('invalid local calls do not wait for initialization', () async {
      mockChannel = buildMockChannel();
      final initCompleter = Completer<void>();
      when(mockChannel.invokeMethod<void>('init', any))
          .thenAnswer((_) => initCompleter.future);
      amplitude = Amplitude(testConfiguration, mockChannel);

      await amplitude.setGroup(testGroupType, 1);
      await amplitude.revenue(Revenue());

      verifyNever(mockChannel.invokeMethod<void>('setGroup', any));
      verifyNever(mockChannel.invokeMethod<void>('revenue', any));

      initCompleter.complete();
      expect(await amplitude.isBuilt, isTrue);
    });
  }, skip: kIsWeb ? 'Android-only initialization behavior' : false);

  test('non-Android startup calls keep their direct dispatch behavior',
      () async {
    mockChannel = buildMockChannel();
    final initCompleter = Completer<void>();
    when(mockChannel.invokeMethod<void>('init', any))
        .thenAnswer((_) => initCompleter.future);
    when(mockChannel.invokeMethod<void>('track', any)).thenAnswer((_) async {});
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    amplitude = Amplitude(testConfiguration, mockChannel);

    await amplitude.track(BaseEvent('direct'));

    verify(mockChannel.invokeMethod<void>('track', any)).called(1);
    verifyNever(mockChannel.invokeMethod<void>('awaitBuild', any));
    initCompleter.complete();
    expect(await amplitude.isBuilt, isTrue);
  });

  // Reset the mock method call handler after each test
  tearDown(() {
    clearInteractions(mockChannel);
  });
}
