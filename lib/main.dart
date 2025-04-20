import 'dart:async';
import 'dart:io';
import 'dart:isolate';
// import 'dart:ui' as ui; // RootIsolateToken 사용 시 필요할 수 있으나, flutter/services에서 re-export 함
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // RootIsolateToken, BackgroundIsolateBinaryMessenger 사용
import 'package:google_mlkit_commons/google_mlkit_commons.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';


late List<CameraDescription> _cameras;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    _cameras = await availableCameras();
  } on CameraException catch (e) {
    print('Error finding cameras: ${e.code}, ${e.description}');
    _cameras = [];
  }
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
      home: _cameras.isEmpty
          ? const Scaffold(body: Center(child: Text('사용 가능한 카메라가 없습니다.')))
          : const RealtimeObjectDetectionScreen(),
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
  CameraController? _cameraController;
  int _cameraIndex = 0;
  bool _isCameraInitialized = false;
  bool _isBusy = false;
  List<DetectedObject> _detectedObjects = [];
  Size? _previewSize;
  InputImageRotation? _imageRotation;
  late ObjectDetector _objectDetector;

  Isolate? _objectDetectionIsolate;
  Isolate? _imageRotationIsolate;
  late ReceivePort _objectDetectionReceivePort;
  late ReceivePort _imageRotationReceivePort;
  SendPort? _objectDetectionIsolateSendPort;
  SendPort? _imageRotationIsolateSendPort;
  StreamSubscription? _objectDetectionSubscription;
  StreamSubscription? _imageRotationSubscription;

  bool _isWaitingForRotation = false;
  bool _isWaitingForDetection = false;
  InputImageRotation? _lastCalculatedRotation;
  Size? _lastImageSize;
  Uint8List? _pendingImageDataBytes;
  int? _pendingImageDataWidth;
  int? _pendingImageDataHeight;
  int? _pendingImageDataFormatRaw;
  int? _pendingImageDataBytesPerRow;


  @override
  void initState() {
    super.initState();
    print("initState: Initializing detector...");
    _initializeDetector();
    print("initState: Spawning isolates...");
    _spawnIsolates().then((_) {
       print("initState: Isolates spawned. Initializing camera...");
       if (_cameras.isNotEmpty) {
         _initializeCamera(_cameras[0]);
       } else {
         print("initState: No cameras available.");
       }
    }).catchError((e, stacktrace) {
       print("****** initState: Error spawning isolates: $e");
       print(stacktrace);
       if (mounted) {
         ScaffoldMessenger.of(context).showSnackBar(
           SnackBar(content: Text('백그라운드 작업 초기화 실패: $e')),
         );
       }
    });
  }

  @override
  void dispose() {
    print("dispose: Cleaning up resources...");
    _stopCameraStream();
    _objectDetectionSubscription?.cancel();
    _imageRotationSubscription?.cancel();
    _killIsolates();
    _cameraController?.dispose();
    _objectDetector.close();
    print("dispose: Cleanup complete.");
    super.dispose();
  }

  void _initializeDetector() {
    final options = ObjectDetectorOptions(
      mode: DetectionMode.stream,
      classifyObjects: true,
      multipleObjects: true,
    );
    _objectDetector = ObjectDetector(options: options);
    print("Detector initialized with stream mode.");
  }

  // Isolate 생성 및 리스너 설정 (async)
  Future<void> _spawnIsolates() async {
    Completer<void> rotationPortCompleter = Completer();
    Completer<void> detectionPortCompleter = Completer();

    // --- Object Detection Isolate ---
    // 메인 Isolate의 RootIsolateToken 가져오기 (null 체크 필수!)
    final RootIsolateToken? rootIsolateToken = RootIsolateToken.instance;
    if (rootIsolateToken == null) {
      print("****** Error: Could not get RootIsolateToken in main isolate.");
      detectionPortCompleter.completeError("RootIsolateToken is null");
      // Rotation Isolate 스폰도 중단하거나 에러 처리
      rotationPortCompleter.completeError("RootIsolateToken is null");
      throw Exception("RootIsolateToken is null, cannot spawn detection isolate.");
    }

    print("Spawning Object Detection Isolate...");
    _objectDetectionReceivePort = ReceivePort();
    _objectDetectionIsolate = await Isolate.spawn(
      _detectObjectsIsolate,
      // *** 변경: SendPort와 RootIsolateToken을 리스트로 전달 ***
      [_objectDetectionReceivePort.sendPort, rootIsolateToken],
      onError: _objectDetectionReceivePort.sendPort,
      onExit: _objectDetectionReceivePort.sendPort,
    );

    // ... (Object Detection Listener 로직은 이전과 동일) ...
     _objectDetectionSubscription = _objectDetectionReceivePort.listen((message) {
      if (_objectDetectionIsolateSendPort == null && message is SendPort) {
        _objectDetectionIsolateSendPort = message;
        print('Object Detection Isolate SendPort received.');
        if (!detectionPortCompleter.isCompleted) detectionPortCompleter.complete();
      } else if (message is List<DetectedObject>) {
        // print('_spawnIsolates (Detection Listener): Received ${message.length} objects');
        _isWaitingForDetection = false; // 탐지 완료

        if (mounted) { // 위젯이 아직 마운트 상태인지 확인
          setState(() {
            _detectedObjects = message;
            if (_lastImageSize != null && _lastCalculatedRotation != null) {
                _previewSize = _isRotationSideways(_lastCalculatedRotation!)
                    ? Size(_lastImageSize!.height, _lastImageSize!.width)
                    : Size(_lastImageSize!.width, _lastImageSize!.height);
                _imageRotation = _lastCalculatedRotation;
            }
          });
        } else {
          // print("Detection Listener: Widget not mounted, skipping setState.");
        }

        if (!_isWaitingForRotation && !_isWaitingForDetection && _isBusy) {
           _isBusy = false;
           // print('_spawnIsolates (Detection Listener): All async tasks complete, setting _isBusy = false');
        }
      } else if (message is List && message.length == 2 && message[0] is String && message[0].contains('Error')) {
        print('****** Object Detection Isolate Error: ${message[1]}');
        _isWaitingForDetection = false;
        if (!_isWaitingForRotation) _isBusy = false;
      }
      else {
         print('Object Detection Isolate Listener: Received unexpected message: $message');
          if(_isWaitingForDetection) {
             _isWaitingForDetection = false;
             if (!_isWaitingForRotation) _isBusy = false;
          }
      }
    });


    // --- Image Rotation Isolate ---
    // Image Rotation Isolate는 플랫폼 채널 사용 안 하므로 Token 전달 불필요
    print("Spawning Image Rotation Isolate...");
    _imageRotationReceivePort = ReceivePort();
    _imageRotationIsolate = await Isolate.spawn(
      _getImageRotationIsolate, // 엔트리 포인트 함수 변경 없음
      _imageRotationReceivePort.sendPort, // SendPort만 전달
       onError: _imageRotationReceivePort.sendPort,
       onExit: _imageRotationReceivePort.sendPort,
    );

    // ... (Image Rotation Listener 로직은 이전과 동일) ...
    _imageRotationSubscription = _imageRotationReceivePort.listen((message) {
       if (_imageRotationIsolateSendPort == null && message is SendPort) {
         _imageRotationIsolateSendPort = message;
         print('Image Rotation Isolate SendPort received.');
         if (!rotationPortCompleter.isCompleted) rotationPortCompleter.complete();
       } else if (message is InputImageRotation?) {
           // print('_spawnIsolates (Rotation Listener): Received rotation: $message');
           _isWaitingForRotation = false; // 회전 계산 완료
           _lastCalculatedRotation = message; // 결과 저장

           if (_pendingImageDataBytes != null && _objectDetectionIsolateSendPort != null && message != null) {
              // print('_spawnIsolates (Rotation Listener): Rotation received, sending request to detection isolate...');
              _isWaitingForDetection = true; // 탐지 대기 시작
              _lastImageSize = Size(_pendingImageDataWidth!.toDouble(), _pendingImageDataHeight!.toDouble());

              _objectDetectionIsolateSendPort!.send([
                _pendingImageDataBytes!,
                _pendingImageDataWidth!,
                _pendingImageDataHeight!,
                message, // 방금 받은 회전값 사용
                _pendingImageDataFormatRaw!,
                _pendingImageDataBytesPerRow!,
              ]);
              _pendingImageDataBytes = null; // 전송 후 대기 데이터 클리어
           } else {
              // print('_spawnIsolates (Rotation Listener): Rotation received, but no pending data/detection port/rotation invalid.');
              if (!_isWaitingForDetection && _isBusy) {
                 _isBusy = false;
                 // print('_spawnIsolates (Rotation Listener): No detection needed/pending, setting _isBusy = false');
              }
           }
       } else if (message is List && message.length == 2 && message[0] is String && message[0].contains('Error')) {
         print('****** Image Rotation Isolate Error: ${message[1]}');
         _isWaitingForRotation = false;
         _pendingImageDataBytes = null;
         if (!_isWaitingForDetection) _isBusy = false;
       }
       else {
          print('Image Rotation Isolate Listener: Received unexpected message: $message');
           if(_isWaitingForRotation) {
              _isWaitingForRotation = false;
              _pendingImageDataBytes = null;
              if (!_isWaitingForDetection) _isBusy = false;
           }
       }
    });

    print('_spawnIsolates: Waiting for SendPorts...');
    try {
      await Future.wait([
        rotationPortCompleter.future.timeout(const Duration(seconds: 5)),
        detectionPortCompleter.future.timeout(const Duration(seconds: 5))
      ]);
      print('_spawnIsolates: SendPorts received. Finished spawning and setting up listeners.');
    } catch (e) {
       print("****** Timeout or error waiting for SendPorts: $e");
       // 타임아웃 발생 시 Isolate 종료 등 후속 처리 필요
       _killIsolates(); // 실패 시 Isolate 정리
       throw Exception("Failed to receive SendPorts from isolates: $e");
    }
  }

  void _killIsolates() {
    print("Killing isolates...");
    // Isolate 객체가 null이 아닐 때만 kill 호출
    try { _objectDetectionIsolate?.kill(priority: Isolate.immediate); } catch(e) { print("Error killing detection isolate: $e");}
    try { _imageRotationIsolate?.kill(priority: Isolate.immediate); } catch(e) { print("Error killing rotation isolate: $e");}
    _objectDetectionIsolate = null;
    _imageRotationIsolate = null;
    _objectDetectionIsolateSendPort = null;
    _imageRotationIsolateSendPort = null;
    print("Isolates killed.");
  }

  Future<void> _initializeCamera(CameraDescription cameraDescription) async {
    // ... (이전과 동일) ...
    print('_initializeCamera: Initializing camera: ${cameraDescription.name}');
    if (_cameraController != null) {
      await _stopCameraStream(); // 스트림 먼저 중지
      await _cameraController!.dispose();
      _cameraController = null;
      if(mounted) {
        setState(() { _isCameraInitialized = false; });
      }
    }

    _cameraController = CameraController(
      cameraDescription,
      ResolutionPreset.medium, // 해상도 조절 가능 (high, max 등)
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21 // Android에서 ML Kit 처리에 유리
          : ImageFormatGroup.bgra8888, // iOS 기본 포맷
    );

    try {
      await _cameraController!.initialize();
      print('_initializeCamera: Camera controller initialized.');
      print('_initializeCamera: Starting camera stream...');
      await _startCameraStream(); // 초기화 후 스트림 시작

       if(mounted) {
         setState(() {
           _isCameraInitialized = true;
           _cameraIndex = _cameras.indexOf(cameraDescription);
         });
       }
      print('_initializeCamera: Camera stream started');
    } on CameraException catch (e) {
      print('****** CameraException in _initializeCamera: ${e.code}, ${e.description}');
      if(mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('카메라 초기화 실패: ${e.description}')),
        );
        setState(() { _isCameraInitialized = false; });
      }
    } catch (e, stacktrace) {
      print('****** Unexpected error in _initializeCamera: $e');
      print(stacktrace); // 스택 트레이스 출력
       if(mounted) {
         ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('예상치 못한 카메라 오류: $e')),
         );
         setState(() { _isCameraInitialized = false; });
       }
    }
    print('_initializeCamera: Finished');
  }

  Future<void> _startCameraStream() async {
    // ... (이전과 동일) ...
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      print('Error starting stream: Camera controller is not initialized');
      return;
    }
    if (_cameraController!.value.isStreamingImages) {
      print('Camera stream already running');
      return;
    }
    try {
      // _processCameraImage를 이미지 스트림 콜백으로 등록
      await _cameraController!.startImageStream(_processCameraImage);
      print('_startCameraStream: Camera stream started successfully');
    } on CameraException catch (e) {
      print('****** CameraException in _startCameraStream: ${e.code}, ${e.description}');
    } catch (e, stacktrace) {
      print('****** Unexpected error in _startCameraStream: $e');
      print(stacktrace);
    }
  }

  Future<void> _stopCameraStream() async {
    // ... (이전과 동일, 상태 초기화 포함) ...
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      // print('Error stopping stream: Camera controller is not initialized');
      return;
    }
    if (_cameraController!.value.isStreamingImages) {
      try {
        await _cameraController!.stopImageStream();
        print('Camera stream stopped successfully');
      } on CameraException catch (e) {
        print('****** CameraException in _stopCameraStream: ${e.code}, ${e.description}');
      } catch (e, stacktrace) {
        print('****** Unexpected error in _stopCameraStream: $e');
        print(stacktrace);
      }
    } else {
      // print('Camera stream not running.');
    }
    // 스트림 중지 시 관련 상태 초기화
    _isBusy = false;
    _isWaitingForRotation = false;
    _isWaitingForDetection = false;
    _pendingImageDataBytes = null;
  }

  // 카메라 스트림에서 각 프레임마다 호출되는 함수
  void _processCameraImage(CameraImage image) {
    // ... (이전과 동일) ...
    if (_isBusy || _imageRotationIsolateSendPort == null || _objectDetectionIsolateSendPort == null) {
      // print('Skipping frame');
      return;
    }
    _isBusy = true;
    _isWaitingForRotation = true;
    _isWaitingForDetection = false; // 아직 탐지 대기 아님
    // print('Processing frame...');

    try {
      // --- 1. 이미지 데이터 준비 및 저장 ---
      final WriteBuffer allBytes = WriteBuffer();
      for (final Plane plane in image.planes) {
        allBytes.putUint8List(plane.bytes);
      }
      _pendingImageDataBytes = allBytes.done().buffer.asUint8List();
      _pendingImageDataWidth = image.width;
      _pendingImageDataHeight = image.height;
      _pendingImageDataFormatRaw = image.format.raw;
      _pendingImageDataBytesPerRow = image.planes.isNotEmpty ? image.planes[0].bytesPerRow : 0;

      // --- 2. 회전 계산 요청 ---
      final camera = _cameras[_cameraIndex];
      final orientation = MediaQuery.of(context).orientation;
      final DeviceOrientation deviceRotation;
      if (orientation == Orientation.landscape) {
          deviceRotation = DeviceOrientation.landscapeLeft; // TODO: Handle landscape right
      } else {
          deviceRotation = DeviceOrientation.portraitUp; // TODO: Handle portrait down
      }

      _imageRotationIsolateSendPort!.send([camera.sensorOrientation, deviceRotation]);

    } catch (e, stacktrace) {
      print("****** Error starting processing in _processCameraImage: $e");
      print(stacktrace);
      _pendingImageDataBytes = null;
      _isWaitingForRotation = false;
      _isBusy = false; // 에러 발생 시 busy 플래그 해제
    }
  }

  // ===========================================================================
  //                             Isolate Functions (Static)
  // ===========================================================================

  // Isolate에서 객체 탐지 실행 함수 (static)
  @pragma('vm:entry-point')
  static void _detectObjectsIsolate(List<Object> args) { // *** 변경: 인자를 List<Object>로 받음 ***
    final SendPort mainSendPort = args[0] as SendPort;       // 메인 SendPort 추출
    final RootIsolateToken rootIsolateToken = args[1] as RootIsolateToken; // Token 추출

    // *** 변경: 추출한 Token으로 초기화 ***
    BackgroundIsolateBinaryMessenger.ensureInitialized(rootIsolateToken);

    final ReceivePort receivePort = ReceivePort();
    mainSendPort.send(receivePort.sendPort); // Isolate의 SendPort 전송

    receivePort.listen((message) async {
      try {
        // 메시지 처리 로직은 동일
        final List<dynamic> detectionArgs = message as List<dynamic>;
        final Uint8List bytes = detectionArgs[0];
        final int width = detectionArgs[1];
        final int height = detectionArgs[2];
        final InputImageRotation rotation = detectionArgs[3];
        final int formatRaw = detectionArgs[4];
        final int bytesPerRow = detectionArgs[5];

        final List<DetectedObject> objects = await _detectObjectsImpl(
          bytes, width, height, rotation, formatRaw, bytesPerRow
        );
        mainSendPort.send(objects);
      } catch (e, stacktrace) {
         print("****** Error in _detectObjectsIsolate's listen callback: $e");
         print(stacktrace);
         mainSendPort.send(['Error from Detection Isolate', e.toString()]);
      }
    });
  }

  // ML Kit 객체 탐지 실제 구현 (static, Isolate 내부에서 호출됨)
  static Future<List<DetectedObject>> _detectObjectsImpl(
      Uint8List bytes, int width, int height, InputImageRotation rotation, int formatRaw, int bytesPerRow) async {
    // ... (이전과 동일) ...
     final options = ObjectDetectorOptions(
      mode: DetectionMode.single,
      classifyObjects: true,
      multipleObjects: true,
    );
    final ObjectDetector objectDetector = ObjectDetector(options: options);

    final inputImage = InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: Size(width.toDouble(), height.toDouble()),
        rotation: rotation,
        format: InputImageFormatValue.fromRawValue(formatRaw) ?? InputImageFormat.nv21,
        bytesPerRow: bytesPerRow,
      ),
    );

    try {
       final List<DetectedObject> objects = await objectDetector.processImage(inputImage);
       return objects;
    } catch (e, stacktrace) {
       print("****** Error processing image in _detectObjectsImpl: $e");
       print(stacktrace);
       return <DetectedObject>[];
    } finally {
       await objectDetector.close();
    }
  }

  // Isolate에서 이미지 회전 계산 실행 함수 (static)
  @pragma('vm:entry-point')
  static void _getImageRotationIsolate(SendPort sendPort) { // 인자 변경 없음
    // 플랫폼 채널 사용 안하므로 초기화 불필요
    final ReceivePort receivePort = ReceivePort();
    sendPort.send(receivePort.sendPort);

    receivePort.listen((message) {
       try {
          // 메시지 처리 로직은 동일
          final List<dynamic> args = message as List<dynamic>;
          final int sensorOrientation = args[0];
          final DeviceOrientation deviceOrientation = args[1];

          final InputImageRotation? rotation = _getImageRotationImpl(
            sensorOrientation,
            deviceOrientation,
          );
          sendPort.send(rotation);
       } catch (e, stacktrace) {
          print("****** Error in _getImageRotationIsolate's listen callback: $e");
          print(stacktrace);
          sendPort.send(['Error from Rotation Isolate', e.toString()]);
       }
    });
  }

  // 이미지 회전 계산 실제 구현 (static)
  static InputImageRotation? _getImageRotationImpl(
      int sensorOrientation, DeviceOrientation deviceOrientation) {
    // ... (이전과 동일) ...
     if (Platform.isIOS) {
        int deviceOrientationAngle = 0;
        switch (deviceOrientation) {
            case DeviceOrientation.portraitUp: deviceOrientationAngle = 0; break;
            case DeviceOrientation.landscapeLeft: deviceOrientationAngle = 90; break;
            case DeviceOrientation.portraitDown: deviceOrientationAngle = 180; break;
            case DeviceOrientation.landscapeRight: deviceOrientationAngle = 270; break;
            default: deviceOrientationAngle = 0;
        }
        var compensatedRotation = (sensorOrientation + deviceOrientationAngle) % 360;
        return _rotationIntToInputImageRotation(compensatedRotation);

    } else { // Android
        int deviceOrientationAngle = 0;
         switch (deviceOrientation) {
            case DeviceOrientation.portraitUp: deviceOrientationAngle = 0; break;
            case DeviceOrientation.landscapeLeft: deviceOrientationAngle = 90; break;
            case DeviceOrientation.portraitDown: deviceOrientationAngle = 180; break;
            case DeviceOrientation.landscapeRight: deviceOrientationAngle = 270; break;
            default: deviceOrientationAngle = 0;
        }
        var compensatedRotation = (sensorOrientation - deviceOrientationAngle + 360) % 360;
        return _rotationIntToInputImageRotation(compensatedRotation);
    }
  }

  // Helper to convert rotation degrees to InputImageRotation enum
  static InputImageRotation _rotationIntToInputImageRotation(int rotation) {
    // ... (이전과 동일) ...
     switch (rotation) {
        case 0: return InputImageRotation.rotation0deg;
        case 90: return InputImageRotation.rotation90deg;
        case 180: return InputImageRotation.rotation180deg;
        case 270: return InputImageRotation.rotation270deg;
        default: return InputImageRotation.rotation0deg;
      }
  }

  // ===========================================================================
  //                             Helper & Build Method
  // ===========================================================================

  bool _isRotationSideways(InputImageRotation rotation) {
    // ... (이전과 동일) ...
     return rotation == InputImageRotation.rotation90deg ||
        rotation == InputImageRotation.rotation270deg;
  }

  @override
  Widget build(BuildContext context) {
    // ... (Build 메서드 로직은 이전과 동일, 에러 로깅 및 UI 개선 포함) ...
     final screenSize = MediaQuery.of(context).size;
    Widget cameraPreviewWidget;
    if (_isCameraInitialized && _cameraController != null && _cameraController!.value.isInitialized) {
      final previewRatio = _cameraController!.value.aspectRatio;
      // 화면 크기와 프리뷰 비율을 고려하여 위젯 크기 조정
      cameraPreviewWidget = AspectRatio(
         aspectRatio: previewRatio, // 카메라 프리뷰의 비율을 그대로 사용
         child: CameraPreview(_cameraController!),
      );
      // 필요 시 FittedBox 등으로 화면 채우기
      // cameraPreviewWidget = FittedBox(
      //   fit: BoxFit.cover, // 화면 비율과 달라도 꽉 채움
      //   child: SizedBox(
      //     width: _cameraController!.value.previewSize?.height ?? screenSize.width,  // 회전 고려
      //     height: _cameraController!.value.previewSize?.width ?? screenSize.height, // 회전 고려
      //     child: CameraPreview(_cameraController!),
      //   ),
      // );
    } else {
      cameraPreviewWidget = Container(color: Colors.black, child: const Center(child: CircularProgressIndicator()));
    }


    return Scaffold(
      appBar: AppBar(
        title: const Text('실시간 객체 탐지'),
        actions: [
          if (_cameras.length > 1)
            IconButton(
              icon: Icon(
                  _cameras[_cameraIndex].lensDirection == CameraLensDirection.front
                   ? Icons.camera_front
                   : Icons.camera_rear),
              onPressed: _isBusy
                  ? null
                  : () {
                      print("Switching camera...");
                      final newIndex = (_cameraIndex + 1) % _cameras.length;
                      _stopCameraStream().then((_) {
                         _initializeCamera(_cameras[newIndex]);
                      });
                    },
            ),
        ],
      ),
      body: Stack(
              fit: StackFit.expand,
              children: [
                Center(child: cameraPreviewWidget),
                // 객체 탐지 결과 그리기
                if (_isCameraInitialized && _detectedObjects.isNotEmpty && _lastImageSize != null)
                  LayoutBuilder( // CustomPaint가 차지하는 실제 크기를 얻기 위해 사용
                     builder: (context, constraints) {
                       return CustomPaint(
                         // painter가 사용할 크기를 LayoutBuilder로부터 전달 받음
                         size: constraints.biggest,
                         painter: ObjectPainter(
                           objects: _detectedObjects,
                           imageSize: _lastImageSize!,
                           rotation: _imageRotation ?? InputImageRotation.rotation0deg,
                           cameraLensDirection: _cameras[_cameraIndex].lensDirection,
                         ),
                       );
                     }
                  ),
                // 로딩 인디케이터
                if (_isBusy)
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
//                             ObjectPainter Class
// ===========================================================================
class ObjectPainter extends CustomPainter {
  // ... (이전과 동일) ...
  final List<DetectedObject> objects;
  final Size imageSize;
  final InputImageRotation rotation;
  final CameraLensDirection cameraLensDirection;

  ObjectPainter({
    required this.objects,
    required this.imageSize,
    required this.rotation,
    required this.cameraLensDirection,
  });

  Rect _scaleAndTranslateRect(Rect boundingBox, Size canvasSize) {
     // ... (이전과 동일, clamp 및 L<R, T<B 보장 로직 포함) ...
     final double imageWidth = imageSize.width;
    final double imageHeight = imageSize.height;
    final double canvasWidth = canvasSize.width;
    final double canvasHeight = canvasSize.height;

    final double scaleX, scaleY;
    if (_isRotationSideways(rotation)) {
      scaleX = canvasWidth / imageHeight;
      scaleY = canvasHeight / imageWidth;
    } else {
      scaleX = canvasWidth / imageWidth;
      scaleY = canvasHeight / imageHeight;
    }

    double L, T, R, B;
    switch (rotation) {
      case InputImageRotation.rotation90deg:
        L = boundingBox.top * scaleX;
        T = (imageWidth - boundingBox.right) * scaleY;
        R = boundingBox.bottom * scaleX;
        B = (imageWidth - boundingBox.left) * scaleY;
        break;
      case InputImageRotation.rotation180deg:
        L = (imageWidth - boundingBox.right) * scaleX;
        T = (imageHeight - boundingBox.bottom) * scaleY;
        R = (imageWidth - boundingBox.left) * scaleX;
        B = (imageHeight - boundingBox.top) * scaleY;
        break;
      case InputImageRotation.rotation270deg:
        L = (imageHeight - boundingBox.bottom) * scaleX;
        T = boundingBox.left * scaleY;
        R = (imageHeight - boundingBox.top) * scaleX;
        B = boundingBox.right * scaleY;
        break;
      case InputImageRotation.rotation0deg:
      default:
        L = boundingBox.left * scaleX;
        T = boundingBox.top * scaleY;
        R = boundingBox.right * scaleX;
        B = boundingBox.bottom * scaleY;
        break;
    }

    if (cameraLensDirection == CameraLensDirection.front && Platform.isAndroid) {
        double tempL = L;
        L = canvasWidth - R;
        R = canvasWidth - tempL;
    }

    L = L.clamp(0.0, canvasWidth);
    T = T.clamp(0.0, canvasHeight);
    R = R.clamp(0.0, canvasWidth);
    B = B.clamp(0.0, canvasHeight);

    if (L > R) { double temp = L; L = R; R = temp; }
    if (T > B) { double temp = T; T = B; B = temp; }

    return Rect.fromLTRB(L, T, R, B);
  }

   bool _isRotationSideways(InputImageRotation rotation) {
    return rotation == InputImageRotation.rotation90deg ||
        rotation == InputImageRotation.rotation270deg;
  }

  @override
  void paint(Canvas canvas, Size size) {
    // ... (이전과 동일, 텍스트 위치 조정 및 범위 제한 로직 포함) ...
    final Paint paintRect = Paint()
      ..color = Colors.redAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    final Paint paintBackground = Paint()..color = Colors.black.withOpacity(0.6);

    if (imageSize.isEmpty) {
       // print("ObjectPainter: Warning - imageSize is empty.");
       return;
    }

    for (final DetectedObject detectedObject in objects) {
      final Rect canvasRect = _scaleAndTranslateRect(detectedObject.boundingBox, size);

      if (canvasRect.width > 0 && canvasRect.height > 0) {
        canvas.drawRect(canvasRect, paintRect);

        if (detectedObject.labels.isNotEmpty) {
          final Label label = detectedObject.labels.first;
          final TextPainter textPainter = TextPainter(
            text: TextSpan(
              text: ' ${label.text} (${(label.confidence * 100).toStringAsFixed(0)}%) ',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12.0,
                backgroundColor: Colors.black54,
              ),
            ),
            textDirection: TextDirection.ltr,
          );

          textPainter.layout(minWidth: 0, maxWidth: size.width);

          double textY = canvasRect.top - textPainter.height;
          if (textY < 0) {
            textY = canvasRect.top + 2;
            if(textY + textPainter.height > size.height) {
               textY = canvasRect.bottom - textPainter.height - 2;
            }
          }
          final Offset textOffset = Offset(canvasRect.left, textY.clamp(0.0, size.height - textPainter.height));

          textPainter.paint(canvas, textOffset);
        }
      } else {
         // print("Skipping drawing invalid rect: $canvasRect");
      }
    }
  }

  @override
  bool shouldRepaint(covariant ObjectPainter oldDelegate) {
    // ... (이전과 동일) ...
    return oldDelegate.objects != objects ||
        oldDelegate.imageSize != imageSize ||
        oldDelegate.rotation != rotation ||
        oldDelegate.cameraLensDirection != cameraLensDirection;
  }
}