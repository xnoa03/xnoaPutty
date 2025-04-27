import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:camera/camera.dart'; // --- 카메라 관련 ---
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart'; // --- ML Kit 사용 관련 ---
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart'; // --- ML Kit 사용 관련 ---

// --- 카메라 관련 시작 ---
late List<CameraDescription> _cameras;
// --- 카메라 관련 끝 ---

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // --- 카메라 관련 시작 ---
  try {
    _cameras = await availableCameras();
  } on CameraException catch (e) {
    print('****** Error finding cameras: ${e.code}, ${e.description}');
    _cameras = [];
  }
  // --- 카메라 관련 끝 ---
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Realtime Object Detection',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      // --- 카메라 관련 시작 ---
      home: _cameras.isEmpty
          ? const Scaffold(body: Center(child: Text('No available cameras.')))
          : const RealtimeObjectDetectionScreen(),
      // --- 카메라 관련 끝 ---
    );
  }
}

class RealtimeObjectDetectionScreen extends StatefulWidget {
  const RealtimeObjectDetectionScreen({Key? key});

  @override
  _RealtimeObjectDetectionScreenState createState() =>
      _RealtimeObjectDetectionScreenState();
}

class _RealtimeObjectDetectionScreenState
    extends State<RealtimeObjectDetectionScreen> {

  // --- 카메라 관련 시작 ---
  CameraController? _cameraController;
  int _cameraIndex = 0;
  bool _isCameraInitialized = false;
  // --- 카메라 관련 끝 ---

  // --- 공통 상태 관리 ---
  bool _isBusy = false;
  bool _isWaitingForRotation = false;
  bool _isWaitingForDetection = false;
  // --- 공통 상태 관리 끝 ---

  // --- ML Kit 사용 관련 시작 ---
  List<DetectedObject> _detectedObjects = []; // 바운더리 박스 및 네임태그 데이터 포함
  Size? _lastImageSize;
  InputImageRotation? _imageRotation;
  late ObjectDetector _objectDetector;
  // --- ML Kit 사용 관련 끝 ---

  // --- Isolate (백그라운드 처리) 관련 ---
  Isolate? _objectDetectionIsolate;
  Isolate? _imageRotationIsolate;
  late ReceivePort _objectDetectionReceivePort;
  late ReceivePort _imageRotationReceivePort;
  SendPort? _objectDetectionIsolateSendPort;
  SendPort? _imageRotationIsolateSendPort;
  StreamSubscription? _objectDetectionSubscription;
  StreamSubscription? _imageRotationSubscription;
  // --- Isolate 관련 끝 ---

  // --- ML Kit 사용 관련 시작 (InputImage 데이터) ---
  Uint8List? _pendingImageDataBytes;
  int? _pendingImageDataWidth;
  int? _pendingImageDataHeight;
  int? _pendingImageDataFormatRaw;
  int? _pendingImageDataBytesPerRow;
  InputImageRotation? _lastCalculatedRotation;
   // --- ML Kit 사용 관련 끝 ---

  @override
  void initState() {
    super.initState();
    // --- ML Kit 사용 관련 시작 ---
    _initializeDetector();
    // --- ML Kit 사용 관련 끝 ---
    _spawnIsolates().then((_) { // Isolate 스폰 (ML Kit, 회전 계산 포함)
      // --- 카메라 관련 시작 ---
      if (_cameras.isNotEmpty) {
        _initializeCamera(_cameras[0]);
      } else {
        print("initState: No cameras available.");
      }
       // --- 카메라 관련 끝 ---
    }).catchError((e, stacktrace) {
      print("****** initState: Error spawning isolates: $e");
      print(stacktrace);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Background task initialization failed: $e')),
        );
      }
    });
  }

  @override
  void dispose() {
    // --- 카메라 관련 시작 ---
    _stopCameraStream();
    // --- 카메라 관련 끝 ---
    _objectDetectionSubscription?.cancel(); // Isolate 리스너 정리
    _imageRotationSubscription?.cancel();  // Isolate 리스너 정리
    _killIsolates(); // Isolate 종료
    // --- 카메라 관련 시작 ---
    _cameraController?.dispose();
    // --- 카메라 관련 끝 ---
    // --- ML Kit 사용 관련 시작 ---
    _objectDetector.close();
    // --- ML Kit 사용 관련 끝 ---
    super.dispose();
  }

  // --- ML Kit 사용 관련 시작 ---
  void _initializeDetector() {
    final options = ObjectDetectorOptions(
      mode: DetectionMode.stream,
      classifyObjects: true, // 네임태그 분류 활성화
      multipleObjects: true,
    );
    _objectDetector = ObjectDetector(options: options);
  }
  // --- ML Kit 사용 관련 끝 ---

  // --- Isolate (백그라운드 처리) 관련 시작 ---
  // (_spawnIsolates, _killIsolates 는 Isolate 관리 로직이므로 별도 표시)
  Future<void> _spawnIsolates() async {
    Completer<void> rotationPortCompleter = Completer();
    Completer<void> detectionPortCompleter = Completer();

    final RootIsolateToken? rootIsolateToken = RootIsolateToken.instance;
    if (rootIsolateToken == null) {
      print("****** Error: Could not get RootIsolateToken in main isolate.");
      final error = Exception("RootIsolateToken is null, cannot spawn detection isolate.");
      detectionPortCompleter.completeError(error);
      rotationPortCompleter.completeError(error);
      throw error;
    }

    // Object Detection Isolate (ML Kit 사용)
    _objectDetectionReceivePort = ReceivePort();
    _objectDetectionIsolate = await Isolate.spawn(
      _detectObjectsIsolate, // ML Kit 처리 함수 호출
      [_objectDetectionReceivePort.sendPort, rootIsolateToken],
      onError: _objectDetectionReceivePort.sendPort,
      onExit: _objectDetectionReceivePort.sendPort,
    );

    _objectDetectionSubscription = _objectDetectionReceivePort.listen((message) {
      if (_objectDetectionIsolateSendPort == null && message is SendPort) {
        _objectDetectionIsolateSendPort = message;
        if (!detectionPortCompleter.isCompleted) detectionPortCompleter.complete();
      // --- ML Kit 사용 관련 시작 (결과 수신) ---
      } else if (message is List<DetectedObject>) {
        _isWaitingForDetection = false;
        if (mounted) {
          setState(() {
            _detectedObjects = message; // ML Kit 결과 저장 (바운더리 박스, 네임태그 정보 포함)
            _imageRotation = _lastCalculatedRotation; // 그림 그릴 때 필요한 회전값 업데이트
          });
        }
        if (!_isWaitingForRotation && !_isWaitingForDetection && _isBusy) {
          _isBusy = false;
        }
      // --- ML Kit 사용 관련 끝 ---
      } else if (message is List && message.length == 2 && message[0] is String && message[0].contains('Error')) {
        print('****** Object Detection Isolate Error: ${message[1]}');
        _isWaitingForDetection = false;
        if (!_isWaitingForRotation) _isBusy = false;
      } else {
        print('Object Detection Isolate Listener: Received unexpected message: $message');
        if (_isWaitingForDetection) {
          _isWaitingForDetection = false;
          if (!_isWaitingForRotation) _isBusy = false;
        }
      }
    });

    // Image Rotation Isolate (ML Kit 사용 위한 회전 계산)
    _imageRotationReceivePort = ReceivePort();
    _imageRotationIsolate = await Isolate.spawn(
      _getImageRotationIsolate, // 회전 계산 함수 호출
      _imageRotationReceivePort.sendPort,
      onError: _imageRotationReceivePort.sendPort,
      onExit: _imageRotationReceivePort.sendPort,
    );

    _imageRotationSubscription = _imageRotationReceivePort.listen((message) {
      if (_imageRotationIsolateSendPort == null && message is SendPort) {
        _imageRotationIsolateSendPort = message;
        if (!rotationPortCompleter.isCompleted) rotationPortCompleter.complete();
      // --- ML Kit 사용 관련 시작 (회전값 수신 및 다음 단계 요청) ---
      } else if (message is InputImageRotation?) {
        _isWaitingForRotation = false;
        _lastCalculatedRotation = message; // 계산된 회전값 저장

        // 회전값 받고 ML Kit 탐지 Isolate에 데이터 전송
        if (_pendingImageDataBytes != null && _objectDetectionIsolateSendPort != null && message != null) {
          _isWaitingForDetection = true;
          _lastImageSize = Size(_pendingImageDataWidth!.toDouble(), _pendingImageDataHeight!.toDouble());

          _objectDetectionIsolateSendPort!.send([
            _pendingImageDataBytes!,
            _pendingImageDataWidth!,
            _pendingImageDataHeight!,
            message, // 계산된 InputImageRotation 사용
            _pendingImageDataFormatRaw!,
            _pendingImageDataBytesPerRow!,
          ]);
          _pendingImageDataBytes = null;
        } else {
          if (!_isWaitingForDetection && _isBusy) {
            _isBusy = false;
          }
        }
       // --- ML Kit 사용 관련 끝 ---
      } else if (message is List && message.length == 2 && message[0] is String && message[0].contains('Error')) {
        print('****** Image Rotation Isolate Error: ${message[1]}');
        _isWaitingForRotation = false;
        _pendingImageDataBytes = null;
        if (!_isWaitingForDetection) _isBusy = false;
      } else {
        print('Image Rotation Isolate Listener: Received unexpected message: $message');
        if (_isWaitingForRotation) {
          _isWaitingForRotation = false;
          _pendingImageDataBytes = null;
          if (!_isWaitingForDetection) _isBusy = false;
        }
      }
    });

    try {
      await Future.wait([
        rotationPortCompleter.future.timeout(const Duration(seconds: 5)),
        detectionPortCompleter.future.timeout(const Duration(seconds: 5))
      ]);
    } catch (e) {
      print("****** Timeout or error waiting for SendPorts: $e");
      _killIsolates();
      throw Exception("Failed to receive SendPorts from isolates: $e");
    }
  }

  void _killIsolates() {
    try { _objectDetectionIsolate?.kill(priority: Isolate.immediate); } catch(e) { print("Error killing detection isolate: $e");}
    try { _imageRotationIsolate?.kill(priority: Isolate.immediate); } catch(e) { print("Error killing rotation isolate: $e");}
    _objectDetectionIsolate = null;
    _imageRotationIsolate = null;
    _objectDetectionIsolateSendPort = null;
    _imageRotationIsolateSendPort = null;
  }
   // --- Isolate (백그라운드 처리) 관련 끝 ---


  // --- 카메라 관련 시작 ---
  Future<void> _initializeCamera(CameraDescription cameraDescription) async {
    if (_cameraController != null) {
      await _stopCameraStream();
      await _cameraController!.dispose();
      _cameraController = null;
      if (mounted) {
        setState(() { _isCameraInitialized = false; });
      }
    }

    _cameraController = CameraController(
      cameraDescription,
      ResolutionPreset.medium,
      enableAudio: false,
      // --- ML Kit 사용 관련 시작 (이미지 포맷) ---
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21 // 안드로이드 ML Kit 에 최적화된 포맷
          : ImageFormatGroup.bgra8888,
      // --- ML Kit 사용 관련 끝 ---
    );

    try {
      await _cameraController!.initialize();
      await _startCameraStream();

      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
          _cameraIndex = _cameras.indexOf(cameraDescription);
        });
      }
    } on CameraException catch (e) {
      print('****** CameraException in _initializeCamera: ${e.code}, ${e.description}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Camera initialization failed: ${e.description}')),
        );
        setState(() { _isCameraInitialized = false; });
      }
    } catch (e, stacktrace) {
      print('****** Unexpected error in _initializeCamera: $e');
      print(stacktrace);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
         SnackBar(content: Text('Unexpected camera error: $e')),
        );
        setState(() { _isCameraInitialized = false; });
      }
    }
  }

  Future<void> _startCameraStream() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      print('Error starting stream: Camera controller is not initialized');
      return;
    }
    if (_cameraController!.value.isStreamingImages) {
      return;
    }
    try {
      await _cameraController!.startImageStream(_processCameraImage); // 프레임 처리 함수 연결
    } on CameraException catch (e) {
      print('****** CameraException in _startCameraStream: ${e.code}, ${e.description}');
    } catch (e, stacktrace) {
      print('****** Unexpected error in _startCameraStream: $e');
      print(stacktrace);
    }
  }

  Future<void> _stopCameraStream() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }
    if (_cameraController!.value.isStreamingImages) {
      try {
        await _cameraController!.stopImageStream();
      } on CameraException catch (e) {
        print('****** CameraException in _stopCameraStream: ${e.code}, ${e.description}');
      } catch (e, stacktrace) {
        print('****** Unexpected error in _stopCameraStream: $e');
        print(stacktrace);
      }
    }
    _isBusy = false;
    _isWaitingForRotation = false;
    _isWaitingForDetection = false;
    _pendingImageDataBytes = null;
  }
  // --- 카메라 관련 끝 ---


  // --- 카메라 관련 시작 (프레임 수신) & ML Kit 사용 관련 시작 (데이터 준비 및 전송) ---
  void _processCameraImage(CameraImage image) {
    if (_isBusy || _imageRotationIsolateSendPort == null || _objectDetectionIsolateSendPort == null) {
      return; // 처리 중이거나 Isolate 준비 안됐으면 프레임 스킵
    }
    _isBusy = true;
    _isWaitingForRotation = true;
    _isWaitingForDetection = false;

    try {
      // ML Kit InputImage 생성을 위한 데이터 추출 및 저장
      final WriteBuffer allBytes = WriteBuffer();
      for (final Plane plane in image.planes) {
        allBytes.putUint8List(plane.bytes);
      }
      _pendingImageDataBytes = allBytes.done().buffer.asUint8List();
      _pendingImageDataWidth = image.width;
      _pendingImageDataHeight = image.height;
      _pendingImageDataFormatRaw = image.format.raw;
      _pendingImageDataBytesPerRow = image.planes.isNotEmpty ? image.planes[0].bytesPerRow : 0;

      // 카메라 센서 방향 정보 추출 (카메라 관련)
      final camera = _cameras[_cameraIndex];
      // 기기 방향 정보 추출 (UI 관련)
      final orientation = MediaQuery.of(context).orientation;
      final DeviceOrientation deviceRotation;
      if (orientation == Orientation.landscape) {
          deviceRotation = DeviceOrientation.landscapeLeft;
      } else {
          deviceRotation = DeviceOrientation.portraitUp;
      }
      // 회전 계산 Isolate 에 센서 방향 & 기기 방향 정보 전송 (ML Kit 사용 관련)
      _imageRotationIsolateSendPort!.send([camera.sensorOrientation, deviceRotation]);

    } catch (e, stacktrace) {
      print("****** Error starting processing in _processCameraImage: $e");
      print(stacktrace);
      _pendingImageDataBytes = null;
      _isWaitingForRotation = false;
      _isBusy = false;
    }
  }
  // --- 카메라 관련 끝 & ML Kit 사용 관련 끝 ---


  // ===========================================================================
  //                        Isolate Functions (Static)
  // ===========================================================================

  // --- ML Kit 사용 관련 시작 (Isolate Entry Point & Logic) ---
  @pragma('vm:entry-point')
  static void _detectObjectsIsolate(List<Object> args) {
    final SendPort mainSendPort = args[0] as SendPort;
    final RootIsolateToken rootIsolateToken = args[1] as RootIsolateToken;

    BackgroundIsolateBinaryMessenger.ensureInitialized(rootIsolateToken); // ML Kit 위한 설정

    final ReceivePort receivePort = ReceivePort();
    mainSendPort.send(receivePort.sendPort);

    receivePort.listen((message) async {
      try {
        final List<dynamic> detectionArgs = message as List<dynamic>;
        final Uint8List bytes = detectionArgs[0];
        final int width = detectionArgs[1];
        final int height = detectionArgs[2];
        final InputImageRotation rotation = detectionArgs[3];
        final int formatRaw = detectionArgs[4];
        final int bytesPerRow = detectionArgs[5];

        // 실제 ML Kit 탐지 로직 호출
        final List<DetectedObject> objects = await _detectObjectsImpl(
          bytes, width, height, rotation, formatRaw, bytesPerRow
        );
        mainSendPort.send(objects); // 결과 전송
      } catch (e, stacktrace) {
        print("****** Error in _detectObjectsIsolate's listen callback: $e");
        print(stacktrace);
        mainSendPort.send(['Error from Detection Isolate', e.toString()]);
      }
    });
  }

  static Future<List<DetectedObject>> _detectObjectsImpl(
      Uint8List bytes, int width, int height, InputImageRotation rotation, int formatRaw, int bytesPerRow) async {
    // Isolate 내에서 ObjectDetector 생성 및 사용
    final options = ObjectDetectorOptions(
      mode: DetectionMode.single,
      classifyObjects: true,
      multipleObjects: true,
    );
    final ObjectDetector objectDetector = ObjectDetector(options: options);

    // InputImage 생성
    final inputImage = InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: Size(width.toDouble(), height.toDouble()),
        rotation: rotation, // 계산된 회전값 적용
        format: InputImageFormatValue.fromRawValue(formatRaw) ?? InputImageFormat.nv21,
        bytesPerRow: bytesPerRow,
      ),
    );

    try {
        // ML Kit 이미지 처리 실행
        final List<DetectedObject> objects = await objectDetector.processImage(inputImage);
        return objects;
    } catch (e, stacktrace) {
        print("****** Error processing image in _detectObjectsImpl: $e");
        print(stacktrace);
        return <DetectedObject>[];
    } finally {
        await objectDetector.close(); // 사용 후 리소스 해제
    }
  }
  // --- ML Kit 사용 관련 끝 ---


  // --- ML Kit 사용 관련 시작 (회전 계산 Isolate Entry Point & Logic) ---
  @pragma('vm:entry-point')
  static void _getImageRotationIsolate(SendPort sendPort) { // ML Kit InputImage 회전 계산용
    final ReceivePort receivePort = ReceivePort();
    sendPort.send(receivePort.sendPort);

    receivePort.listen((message) {
        try {
          final List<dynamic> args = message as List<dynamic>;
          final int sensorOrientation = args[0]; // 카메라 센서 방향
          final DeviceOrientation deviceOrientation = args[1]; // 기기 방향

          // 실제 회전값 계산 로직 호출
          final InputImageRotation? rotation = _getImageRotationImpl(
            sensorOrientation,
            deviceOrientation,
          );
          sendPort.send(rotation); // 계산된 회전값 전송
        } catch (e, stacktrace) {
          print("****** Error in _getImageRotationIsolate's listen callback: $e");
          print(stacktrace);
          sendPort.send(['Error from Rotation Isolate', e.toString()]);
        }
    });
  }

  static InputImageRotation? _getImageRotationImpl(
      int sensorOrientation, DeviceOrientation deviceOrientation) {
    // 플랫폼별 회전 계산 (ML Kit 에 필요한 최종 회전값 계산)
    if (Platform.isIOS) {
       // ... (iOS 회전 계산 로직) ...
       int deviceOrientationAngle = 0; switch (deviceOrientation) { case DeviceOrientation.portraitUp: deviceOrientationAngle = 0; break; case DeviceOrientation.landscapeLeft: deviceOrientationAngle = 90; break; case DeviceOrientation.portraitDown: deviceOrientationAngle = 180; break; case DeviceOrientation.landscapeRight: deviceOrientationAngle = 270; break; default: break; }
       var compensatedRotation = (sensorOrientation + deviceOrientationAngle) % 360;
       return _rotationIntToInputImageRotation(compensatedRotation);
    } else { // Android
       // ... (Android 회전 계산 로직) ...
       int deviceOrientationAngle = 0; switch (deviceOrientation) { case DeviceOrientation.portraitUp: deviceOrientationAngle = 0; break; case DeviceOrientation.landscapeLeft: deviceOrientationAngle = 90; break; case DeviceOrientation.portraitDown: deviceOrientationAngle = 180; break; case DeviceOrientation.landscapeRight: deviceOrientationAngle = 270; break; default: break; }
       var compensatedRotation = (sensorOrientation - deviceOrientationAngle + 360) % 360;
       return _rotationIntToInputImageRotation(compensatedRotation);
    }
  }

  static InputImageRotation _rotationIntToInputImageRotation(int rotation) {
      switch (rotation) {
        case 0: return InputImageRotation.rotation0deg;
        case 90: return InputImageRotation.rotation90deg;
        case 180: return InputImageRotation.rotation180deg;
        case 270: return InputImageRotation.rotation270deg;
        default: return InputImageRotation.rotation0deg;
      }
  }
  // --- ML Kit 사용 관련 끝 ---


  // ===========================================================================
  //                         Helper & Build Method
  // ===========================================================================

  // --- ML Kit 사용 관련 시작 (회전값 헬퍼) ---
  bool _isRotationSideways(InputImageRotation rotation) {
      return rotation == InputImageRotation.rotation90deg ||
         rotation == InputImageRotation.rotation270deg;
  }
  // --- ML Kit 사용 관련 끝 ---

  @override
  Widget build(BuildContext context) {
    Widget cameraPreviewWidget;
    // --- 카메라 관련 시작 (미리보기 위젯 생성) ---
    if (_isCameraInitialized && _cameraController != null && _cameraController!.value.isInitialized) {
      cameraPreviewWidget = AspectRatio(
          aspectRatio: _cameraController!.value.aspectRatio,
          child: CameraPreview(_cameraController!),
      );
    } else {
      cameraPreviewWidget = Container(color: Colors.black, child: const Center(child: CircularProgressIndicator()));
    }
    // --- 카메라 관련 끝 ---

    return Scaffold(
      appBar: AppBar(
        title: const Text('Real-time Object Detection'),
        actions: [
          // --- 카메라 관련 시작 (카메라 전환 버튼) ---
          if (_cameras.length > 1)
            IconButton(
              icon: Icon(
                  _cameras[_cameraIndex].lensDirection == CameraLensDirection.front
                  ? Icons.camera_front
                  : Icons.camera_rear),
              onPressed: _isBusy
                  ? null
                  : () {
                      final newIndex = (_cameraIndex + 1) % _cameras.length;
                      _stopCameraStream().then((_) {
                          _initializeCamera(_cameras[newIndex]);
                      });
                    },
            ),
            // --- 카메라 관련 끝 ---
        ],
      ),
      body: Stack(
          fit: StackFit.expand,
          children: [
            // --- 카메라 관련 시작 (미리보기 표시) ---
            Center(child: cameraPreviewWidget),
            // --- 카메라 관련 끝 ---

            // --- 바운더리 박스 시작 & 바운더리 박스 네임태그 시작 ---
            // (ObjectPainter 가 두 가지 모두 처리)
            // --- ML Kit 사용 관련 시작 (결과 사용 조건) ---
            if (_isCameraInitialized && _detectedObjects.isNotEmpty && _lastImageSize != null && _imageRotation != null)
            // --- ML Kit 사용 관련 끝 ---
              LayoutBuilder(
                  builder: (context, constraints) {
                    return CustomPaint(
                      size: constraints.biggest,
                      painter: ObjectPainter( // Painter 호출
                        // --- ML Kit 사용 관련 시작 (결과 전달) ---
                        objects: _detectedObjects,
                        // --- ML Kit 사용 관련 끝 ---
                        imageSize: _lastImageSize!, // ML Kit InputImage 크기
                        rotation: _imageRotation!, // ML Kit InputImage 회전
                        // --- 카메라 관련 시작 (렌즈 방향 전달) ---
                        cameraLensDirection: _cameras[_cameraIndex].lensDirection,
                        // --- 카메라 관련 끝 ---
                      ),
                    );
                  }
              ),
             // --- 바운더리 박스 끝 & 바운더리 박스 네임태그 끝 ---

            if (_isBusy) // 처리 중 오버레이 (공통 상태)
              Container(
                color: Colors.black.withOpacity(0.3),
                child: const Center(child: CircularProgressIndicator(color: Colors.white)),
              ),
          ],
        ),
    );
  }
}


// ===========================================================================
//                           ObjectPainter Class
// ===========================================================================
// --- 바운더리 박스 시작 & 바운더리 박스 네임태그 시작 ---
class ObjectPainter extends CustomPainter {
  // --- ML Kit 사용 관련 시작 (입력 데이터) ---
  final List<DetectedObject> objects;
  final Size imageSize; // ML Kit InputImage 크기
  final InputImageRotation rotation; // ML Kit InputImage 회전
  // --- ML Kit 사용 관련 끝 ---
  // --- 카메라 관련 시작 (입력 데이터) ---
  final CameraLensDirection cameraLensDirection; // 미러링 계산용
  // --- 카메라 관련 끝 ---

  ObjectPainter({
    required this.objects,
    required this.imageSize,
    required this.rotation,
    required this.cameraLensDirection,
  });

  // --- 바운더리 박스 시작 (좌표 변환) ---
  Rect _scaleAndTranslateRect(Rect boundingBox, Size canvasSize) {
    // (ML Kit 좌표 -> 화면 좌표 변환 로직)
    // ... 이미지 크기, 캔버스 크기, 회전, 카메라 방향 고려 ...
    final double imageWidth = imageSize.width; final double imageHeight = imageSize.height; final double canvasWidth = canvasSize.width; final double canvasHeight = canvasSize.height;
    final double scaleX, scaleY; if (_isRotationSideways(rotation)) { scaleX = canvasWidth / imageHeight; scaleY = canvasHeight / imageWidth; } else { scaleX = canvasWidth / imageWidth; scaleY = canvasHeight / imageHeight; }
    double L, T, R, B; switch (rotation) { case InputImageRotation.rotation90deg: L = boundingBox.top * scaleX; T = (imageWidth - boundingBox.right) * scaleY; R = boundingBox.bottom * scaleX; B = (imageWidth - boundingBox.left) * scaleY; break; case InputImageRotation.rotation180deg: L = (imageWidth - boundingBox.right) * scaleX; T = (imageHeight - boundingBox.bottom) * scaleY; R = (imageWidth - boundingBox.left) * scaleX; B = (imageHeight - boundingBox.top) * scaleY; break; case InputImageRotation.rotation270deg: L = (imageHeight - boundingBox.bottom) * scaleX; T = boundingBox.left * scaleY; R = (imageHeight - boundingBox.top) * scaleX; B = boundingBox.right * scaleY; break; case InputImageRotation.rotation0deg: default: L = boundingBox.left * scaleX; T = boundingBox.top * scaleY; R = boundingBox.right * scaleX; B = boundingBox.bottom * scaleY; break; }
    // --- 카메라 관련 시작 (미러링 적용) ---
    if (cameraLensDirection == CameraLensDirection.front && Platform.isAndroid) { double tempL = L; L = canvasWidth - R; R = canvasWidth - tempL; }
    // --- 카메라 관련 끝 ---
    L = L.clamp(0.0, canvasWidth); T = T.clamp(0.0, canvasHeight); R = R.clamp(0.0, canvasWidth); B = B.clamp(0.0, canvasHeight);
    if (L > R) { double temp = L; L = R; R = temp; } if (T > B) { double temp = T; T = B; B = temp; }
    return Rect.fromLTRB(L, T, R, B);
  }
  // --- 바운더리 박스 끝 (좌표 변환) ---

  // --- ML Kit 사용 관련 시작 (회전 헬퍼) ---
  bool _isRotationSideways(InputImageRotation rotation) {
    return rotation == InputImageRotation.rotation90deg ||
        rotation == InputImageRotation.rotation270deg;
  }
   // --- ML Kit 사용 관련 끝 ---

  @override
  void paint(Canvas canvas, Size size) {
    // --- 바운더리 박스 시작 (그리기 설정) ---
    final Paint paintRect = Paint()
      ..color = Colors.redAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    // --- 바운더리 박스 끝 (그리기 설정) ---

    if (imageSize.isEmpty) { return; }

    // --- ML Kit 사용 관련 시작 (결과 순회) ---
    for (final DetectedObject detectedObject in objects) {
    // --- ML Kit 사용 관련 끝 ---

      // --- 바운더리 박스 시작 (좌표 계산 및 그리기) ---
      final Rect canvasRect = _scaleAndTranslateRect(detectedObject.boundingBox, size);
      if (canvasRect.width > 0 && canvasRect.height > 0) {
        canvas.drawRect(canvasRect, paintRect); // 박스 그리기
      // --- 바운더리 박스 끝 (좌표 계산 및 그리기) ---

        // --- 바운더리 박스 네임태그 시작 (정보 추출 및 그리기) ---
        // --- ML Kit 사용 관련 시작 (레이블 정보 사용) ---
        if (detectedObject.labels.isNotEmpty) {
          final Label label = detectedObject.labels.first;
          // --- ML Kit 사용 관련 끝 ---
          final TextPainter textPainter = TextPainter(
            text: TextSpan(
              text: ' ${label.text} (${(label.confidence * 100).toStringAsFixed(0)}%) ', // 이름과 신뢰도 표시
              style: const TextStyle(
                color: Colors.white, fontSize: 12.0, backgroundColor: Colors.black54,
              ),
            ),
            textDirection: TextDirection.ltr,
          );
          textPainter.layout(minWidth: 0, maxWidth: size.width);
          // 텍스트 위치 계산 및 조정
          double textY = canvasRect.top - textPainter.height; if (textY < 0) { textY = canvasRect.top + 2; if(textY + textPainter.height > size.height) { textY = canvasRect.bottom - textPainter.height - 2; } }
          final Offset textOffset = Offset(canvasRect.left, textY.clamp(0.0, size.height - textPainter.height));
          textPainter.paint(canvas, textOffset); // 네임태그 그리기
        }
         // --- 바운더리 박스 네임태그 끝 (정보 추출 및 그리기) ---
      }
    }
  }

  @override
  bool shouldRepaint(covariant ObjectPainter oldDelegate) {
    // 변경 사항 감지하여 다시 그릴지 결정 (최적화)
    // objects (박스, 네임태그), imageSize, rotation, cameraLensDirection 중 하나라도 바뀌면 다시 그림
    return oldDelegate.objects != objects ||
        oldDelegate.imageSize != imageSize ||
        oldDelegate.rotation != rotation ||
        oldDelegate.cameraLensDirection != cameraLensDirection;
  }
}
// --- 바운더리 박스 끝 & 바운더리 박스 네임태그 끝 ---
