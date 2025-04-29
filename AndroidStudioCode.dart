import 'dart:async';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:opencv_dart/opencv.dart' as cv;
import 'package:image/image.dart' as img; // For conversion from CameraImage to JPEG

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  runApp(MyApp(cameras: cameras));
}

/// Root widget.
class MyApp extends StatelessWidget {
  final List<CameraDescription> cameras;
  const MyApp({super.key, required this.cameras});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: LightClassifier(cameras: cameras),
      debugShowCheckedModeBanner: false,
    );
  }
}

/// Morse Decoder state machine using frame-count logic.
class MorseDecoder {
  final Map<String, String> morseCodeMap = {
    ".-": "A", "-...": "B", "-.-.": "C", "-..": "D", ".": "E",
    "..-.": "F", "--.": "G", "....": "H", "..": "I", ".---": "J",
    "-.-": "K", ".-..": "L", "--": "M", "-.": "N", "---": "O",
    ".--.": "P", "--.-": "Q", ".-.": "R", "...": "S", "-": "T",
    "..-": "U", "...-": "V", ".--": "W", "-..-": "X", "-.--": "Y",
    "--..": "Z", "-----": "0", ".----": "1", "..---": "2", "...--": "3",
    "....-": "4", ".....": "5", "-....": "6", "--...": "7", "---..": "8",
    "----.": "9"
  };

  // Timestamp-based state variables.
  bool? _lastSignal; // true for ON, false for OFF
  DateTime? _stateStartTime;

  // Buffer for the current letter's Morse symbols.
  String currentLetterSymbols = "";

  // The decoded message.
  String decodedMessage = "";

  /// Call this for every frame along with its timestamp.
  void processSignal(bool isOn, DateTime timestamp) {
    // If this is the very first frame, set initial state.
    if (_lastSignal == null) {
      _lastSignal = isOn;
      _stateStartTime = timestamp;
      return;
    }

    // Only process on state change.
    if (isOn == _lastSignal) return;

    // Compute the duration of the previous state.
    final duration = timestamp.difference(_stateStartTime!).inMilliseconds / 1000.0;

    if (_lastSignal == true) {
      // Previous state was ON: classify duration as dash or dot.
      if (duration <= 0.55) {
        // Dash.
        currentLetterSymbols += '.';
      } else {
        // Dot.
        currentLetterSymbols += '-';
      }
    } else {
      // Previous state was OFF: decide what gap means.
      if (duration <= 0.55) {
        // Very short gap: symbol separator; do nothing.
      } else if (duration <= 1.2) {
        // Letter gap.
        _finalizeLetter();
      } else {
        // Word gap.
        _finalizeLetter();
        decodedMessage += ' ';
      }
    }

    // Update the state.
    _lastSignal = isOn;
    _stateStartTime = timestamp;
  }

  void _finalizeLetter() {
    if (currentLetterSymbols.isNotEmpty) {
      String letter = morseCodeMap[currentLetterSymbols] ?? '?';
      letter = _decrypt(letter);
      decodedMessage += letter;
      currentLetterSymbols = "";
    }
  }

  void flush() {
    _finalizeLetter();
  }

  // Leave the _decrypt method as-is, or adjust if needed.
  String _decrypt(String encryptedLetter) {
    if (encryptedLetter == "?") return encryptedLetter;
    int code = encryptedLetter.codeUnitAt(0);
    int decryptedCode = code - 3;
    if (decryptedCode < 65) {
      decryptedCode += 26;
    }
    return String.fromCharCode(decryptedCode);
  }

  String getDecodedMessage() {
    return decodedMessage;
  }
}

/// Main widget for camera preview and decoding.
class LightClassifier extends StatefulWidget {
  final List<CameraDescription> cameras;
  const LightClassifier({super.key, required this.cameras});
  @override
  State<LightClassifier> createState() => _LightClassifierState();
}

class _LightClassifierState extends State<LightClassifier> with WidgetsBindingObserver {
  CameraController? _controller;
  bool _isStreaming = false; // Streaming flag
  bool _isProcessingFrame = false;
  final MorseDecoder decoder = MorseDecoder();
  List<String> frameClassifications = [];

  Uint8List? latestJpeg;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  /// Monitors app lifecycle changes.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      resetCamera();
    } else if (state == AppLifecycleState.paused) {
      if (_controller != null && _controller!.value.isStreamingImages) {
        _controller!.stopImageStream();
      }
      _controller?.dispose();
    }
  }

  /// Initializes or resets the camera.
  Future<void> resetCamera() async {
    if (_controller != null) {
      await _controller!.dispose();
    }
    // Use a lower resolution (e.g., medium) for performance.
    _controller = CameraController(
      widget.cameras[0],
      ResolutionPreset.medium,
      enableAudio: false,
    );
    await _controller!.initialize();
    if (mounted) setState(() {});
  }

  Future<void> _initializeCamera() async {
    await resetCamera();
  }

  /// Starts streaming frames using startImageStream for efficient processing.
  void _startStream() {
    if (_controller == null || !_controller!.value.isInitialized) return;
    setState(() => _isStreaming = true);
    _controller!.startImageStream((CameraImage image) {
      final captureTimestamp = DateTime.now(); // Capture timestamp when the frame is received.
      if (!_isProcessingFrame) {
        _processCameraImage(image, captureTimestamp);
      }
    });
  }

  /// Stops the image stream.
  void _stopStream() {
    if (_controller != null && _controller!.value.isStreamingImages) {
      _controller!.stopImageStream();
    }
    setState(() => _isStreaming = false);
    // Flush the last pending letter.
    decoder.flush();
  }


  /// Processes a CameraImage frame.
  Future<void> _processCameraImage(CameraImage image, DateTime captureTimestamp) async {
    _isProcessingFrame = true;

    try {
      // Convert CameraImage to JPEG bytes for classification.
      Uint8List jpegData = await convertYUV420toJPEG(image);
      setState(() {
        latestJpeg = jpegData;
      });

      String result = await compute(processImageIsolate, jpegData);
      // Format the result with the capture timestamp.
      String formattedResult = "${captureTimestamp.toIso8601String()} - $result";
      setState(() {
        frameClassifications.add(formattedResult); // Add the new frame result with timestamp.
      });
      bool isOn = result.toLowerCase() == "on";
      // Use the captured timestamp for decoding.
      decoder.processSignal(isOn, captureTimestamp);
    } catch (e) {
      debugPrint("Error processing frame: $e");
    }
    _isProcessingFrame = false;
  }

  /// Converts YUV420 CameraImage to JPEG using the image package.
  Future<Uint8List> convertYUV420toJPEG(CameraImage image) async {
    final int width = image.width;
    final int height = image.height;

    // Create an empty RGB image using the 'image' package.
    final img.Image rgbImage = img.Image(width: width, height: height);

    // Extract the Y, U, and V planes.
    final Plane yPlane = image.planes[0];
    final Plane uPlane = image.planes[1];
    final Plane vPlane = image.planes[2];

    // Read row strides and bytesPerPixel for each plane.
    final int yRowStride = yPlane.bytesPerRow;
    final int yPixelStride = yPlane.bytesPerPixel ?? 1;
    final int uRowStride = uPlane.bytesPerRow;
    final int uPixelStride = uPlane.bytesPerPixel ?? 1;
    final int vRowStride = vPlane.bytesPerRow;
    final int vPixelStride = vPlane.bytesPerPixel ?? 1;

    // Iterate over each pixel.
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        // Index for Y-plane.
        final int yIndex = row * yRowStride + col * yPixelStride;
        final int Y = yPlane.bytes[yIndex] & 0xFF;

        // Since U/V are subsampled by 2 in both directions (NV21 / YUV_420).
        final int uvRow = row ~/ 2;
        final int uvCol = col ~/ 2;

        // U-plane index.
        final int uIndex = uvRow * uRowStride + uvCol * uPixelStride;
        final int U = uPlane.bytes[uIndex] & 0xFF;

        // V-plane index.
        final int vIndex = uvRow * vRowStride + uvCol * vPixelStride;
        final int V = vPlane.bytes[vIndex] & 0xFF;

        // YUV to RGB conversion.
        final int C = Y - 16;
        final int D = U - 128;
        final int E = V - 128;

        int R = (298 * C + 409 * E + 128) >> 8;
        int G = (298 * C - 100 * D - 208 * E + 128) >> 8;
        int B = (298 * C + 516 * D + 128) >> 8;

        // Clamp to [0..255].
        R = R.clamp(0, 255);
        G = G.clamp(0, 255);
        B = B.clamp(0, 255);

        // Write the pixel into the output image.
        rgbImage.setPixelRgba(col, row, R, G, B, 255);
      }
    }

    // Finally, encode the RGB image as a JPEG.
    return Uint8List.fromList(img.encodeJpg(rgbImage, quality: 90));
  }

  // In your _LightClassifierState build method, update the camera preview container:
  @override
  Widget build(BuildContext context) {
    final screenH = MediaQuery.of(context).size.height;
    return Scaffold(
      appBar: AppBar(title: const Text("Morse Decrypter")),
      body: Column(
        children: [
          // Camera preview with black background.
          Container(
            height: screenH * 0.5,
            color: Colors.black, // Set background to black.
            child: Stack(
              children: [
                (_controller != null && _controller!.value.isInitialized)
                    ? CameraPreview(_controller!)
                    : const Center(child: CircularProgressIndicator()),
                Positioned(
                  bottom: 16,
                  left: 16,
                  child: ElevatedButton(
                    onPressed: _isStreaming ? null : _startStream,
                    child: const Text("Start"),
                  ),
                ),
                Positioned(
                  bottom: 16,
                  right: 16,
                  child: ElevatedButton(
                    onPressed: _isStreaming ? _stopStream : null,
                    child: const Text("Stop"),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // Graph for classification results with a black background.
          Expanded(
            child: Container(
              color: Colors.black, // Black background for the graph.
              child: ClassificationChart(frameClassifications: frameClassifications),
            ),
          ),
          const SizedBox(height: 8),
          // Display the decoded message.
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Text(
              "Decoded Message: ${decoder.decodedMessage}",
              style: const TextStyle(fontSize: 20),
            ),
          ),
        ],
      ),
    );
  }

}

class ClassificationChart extends StatefulWidget {
  final List<String> frameClassifications;
  const ClassificationChart({super.key, required this.frameClassifications});

  @override
  ClassificationChartState createState() => ClassificationChartState();
}

class ClassificationChartState extends State<ClassificationChart> {
  final ScrollController _scrollController = ScrollController();

  @override
  void didUpdateWidget(covariant ClassificationChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.frameClassifications.length >
        oldWidget.frameClassifications.length) {
      _autoScrollToEnd();
    }
  }

  void _autoScrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeOut,
        );
      }
    });
  }


  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      controller: _scrollController,
      child: SizedBox(
        width: widget.frameClassifications.length * 50.0,
        // Adjust width dynamically
        child: CustomPaint(
          size: Size(
              widget.frameClassifications.length * 50.0, double.infinity),
          painter: ClassificationChartPainter(widget.frameClassifications),
        ),
      ),
    );
  }
}

class ClassificationChartPainter extends CustomPainter {
  final List<String> frameClassifications;
  final TextPainter _textPainter = TextPainter(
    textDirection: TextDirection.ltr,
    textAlign: TextAlign.center,
  );

  ClassificationChartPainter(this.frameClassifications);

  @override
  void paint(Canvas canvas, Size size) {
    // Fill background with black.
    final backgroundPaint = Paint()..color = Colors.black;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), backgroundPaint);

    // Define paints for axes, grid, lines, and points.
    final Paint axisPaint = Paint()
      ..color = Colors.grey[600]!
      ..strokeWidth = 1;

    final Paint gridPaint = Paint()
      ..color = Colors.grey[300]!
      ..strokeWidth = 0.5;

    final Paint linePaint = Paint()
      ..shader = LinearGradient(
        colors: [Colors.blueAccent, Colors.lightBlueAccent],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    final Paint pointPaint = Paint()..color = Colors.deepOrangeAccent;

    // Draw horizontal grid lines.
    int gridRows = 2;
    double rowStep = size.height / gridRows;
    for (int i = 0; i <= gridRows; i++) {
      double y = i * rowStep;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    // Draw vertical grid lines.
    int gridCols = 5;
    double colStep = size.width / gridCols;
    for (int i = 0; i <= gridCols; i++) {
      double x = i * colStep;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }

    // Draw x-axis and y-axis.
    canvas.drawLine(Offset(0, size.height), Offset(size.width, size.height), axisPaint);
    canvas.drawLine(Offset(0, 0), Offset(0, size.height), axisPaint);

    // Ensure there is data to plot.
    int count = frameClassifications.length;
    if (count < 2) return;
    double xStep = size.width / (count - 1);

    // Map classification values ("on" or "off") to y coordinates.
    List<Offset> points = [];
    for (int i = 0; i < count; i++) {
      bool isOn = frameClassifications[i].toLowerCase().contains("on");
      // Center the point in the top cell if "on", or in the bottom cell if "off"
      double yValue = isOn ? rowStep / 2 : size.height - rowStep / 2;
      points.add(Offset(i * xStep, yValue));
    }

    // Draw the line connecting the points.
    final Path path = Path()..moveTo(points.first.dx, points.first.dy);
    for (int i = 1; i < points.length; i++) {
      path.lineTo(points[i].dx, points[i].dy);
    }
    canvas.drawPath(path, linePaint);

    // Draw circles for each point.
    for (var point in points) {
      canvas.drawCircle(point, 4, pointPaint);
    }

    // Draw y-axis labels.
    // Draw y-axis labels ("On" at the top and "Off" at the bottom).
    _textPainter.text = const TextSpan(
      text: "On",
      style: TextStyle(fontSize: 12, color: Colors.white),
    );
    _textPainter.layout();
    _textPainter.paint(canvas, const Offset(4, 0));

    _textPainter.text = const TextSpan(
      text: "Off",
      style: TextStyle(fontSize: 12, color: Colors.white),
    );
    _textPainter.layout();
    _textPainter.paint(canvas, Offset(4, size.height - _textPainter.height));


    // Draw x-axis labels at intervals.
    int labelInterval = (count / gridCols).ceil();
    for (int i = 0; i < count; i += labelInterval) {
      String label = i.toString();
      double x = i * xStep;
      _textPainter.text = TextSpan(
        text: label,
        style: const TextStyle(fontSize: 12, color: Colors.white), // White text for contrast.
      );
      _textPainter.layout();
      _textPainter.paint(canvas, Offset(x - _textPainter.width / 2, size.height - _textPainter.height));
    }
  }

  @override
  bool shouldRepaint(covariant ClassificationChartPainter oldDelegate) {
    return oldDelegate.frameClassifications != frameClassifications;
  }
}

/// Top-level function that runs in an isolate to process the image.
/// It decodes the JPEG bytes into an OpenCV Mat, then applies the new
/// image processing logic based on the provided Python code.
String processImageIsolate(Uint8List jpegData) {
  final mat = cv.imdecode(jpegData, cv.IMREAD_COLOR);
  if (mat.data.isEmpty) {
    mat.dispose();
    return "Error";
  }
  final int width = mat.cols;
  final int height = mat.rows;

  // Convert to Lab color space and split channels.
  final labMat = cv.cvtColor(mat, cv.COLOR_BGR2Lab);
  final labChannels = cv.split(labMat);
  if (labChannels.length < 3) {
    labMat.dispose();
    mat.dispose();
    return "Error";
  }
  final aMat = labChannels[1];
  final Uint8List aData = aMat.data;
  const int margin = 100;
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      if (y < margin || y >= height - margin || x < margin || x >= width - margin) {
        final int index = y * width + x;
        aData[index] = 0;
      }
    }
  }
  int maxVal = 0;
  for (int i = 0; i < aData.length; i++) {
    if (aData[i] > maxVal) {
      maxVal = aData[i];
    }
  }
  final String classification = (maxVal > 200) ? "on" : "off";

  // Clean up allocated resources.
  aMat.dispose();
  for (final ch in labChannels) {
    ch.dispose();
  }
  labMat.dispose();
  mat.dispose();

  return classification;
}