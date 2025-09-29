import 'package:flutter/material.dart';
import 'package:ultralytics_yolo/yolo.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'dart:async';
import 'package:video_thumbnail/video_thumbnail.dart';


void main() => runApp(YOLOApp());

class YOLOApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'YOLO Demo',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: YOLODemo(),
    );
  }
}

enum MediaType { image, video }

class YOLODemo extends StatefulWidget {
  @override
  _YOLODemoState createState() => _YOLODemoState();
}

class _YOLODemoState extends State<YOLODemo> {
  YOLO? yolo;
  File? selectedImage;
  File? selectedVideo;
  VideoPlayerController? videoController;
  List<dynamic> results = [];
  bool isLoading = false;
  String statusMessage = "Initializing...";
  MediaType currentMediaType = MediaType.image;
  Timer? detectionTimer;
  bool isDetecting = false;
  bool isVideoProcessing = false;

  // Add variables to store image/video dimensions
  int imageWidth = 0;
  int imageHeight = 0;

  final List<String> cocoLabels = [
    'person', 'bicycle', 'car', 'motorcycle', 'airplane', 'bus', 'train', 'truck', 'boat',
    'traffic light', 'fire hydrant', 'stop sign', 'parking meter', 'bench', 'bird', 'cat',
    'dog', 'horse', 'sheep', 'cow', 'elephant', 'bear', 'zebra', 'giraffe', 'backpack',
    'umbrella', 'handbag', 'tie', 'suitcase', 'frisbee', 'skis', 'snowboard', 'sports ball',
    'kite', 'baseball bat', 'baseball glove', 'skateboard', 'surfboard', 'tennis racket',
    'bottle', 'wine glass', 'cup', 'fork', 'knife', 'spoon', 'bowl', 'banana', 'apple',
    'sandwich', 'orange', 'broccoli', 'carrot', 'hot dog', 'pizza', 'donut', 'cake',
    'chair', 'couch', 'potted plant', 'bed', 'dining table', 'toilet', 'tv', 'laptop',
    'mouse', 'remote', 'keyboard', 'cell phone', 'microwave', 'oven', 'toaster', 'sink',
    'refrigerator', 'book', 'clock', 'vase', 'scissors', 'teddy bear', 'hair drier', 'toothbrush'
  ];

  @override
  void initState() {
    super.initState();
    loadYOLO();
  }

  Future<void> loadYOLO() async {
    setState(() {
      isLoading = true;
      statusMessage = "Loading YOLO model...";
    });

    try {
      yolo = YOLO(
        modelPath: 'yolo11n',
        task: YOLOTask.detect,
        useGpu: false,
      );

      await yolo!.loadModel();

      setState(() {
        isLoading = false;
        statusMessage = "Model loaded successfully!";
      });
    } catch (e) {
      setState(() {
        isLoading = false;
        statusMessage = "Error loading model: $e";
      });
    }
  }

  Future<ui.Image> getImageInfo(Uint8List imageBytes) async {
    final Completer<ui.Image> completer = Completer();
    ui.decodeImageFromList(imageBytes, (ui.Image img) {
      completer.complete(img);
    });
    return completer.future;
  }

  Future<void> pickMedia() async {
    final picker = ImagePicker();

    final MediaType? mediaType = await showDialog<MediaType>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Select Media Type'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.image),
              title: Text('Image'),
              onTap: () => Navigator.pop(context, MediaType.image),
            ),
            ListTile(
              leading: Icon(Icons.videocam),
              title: Text('Video'),
              onTap: () => Navigator.pop(context, MediaType.video),
            ),
          ],
        ),
      ),
    );

    if (mediaType == null) return;

    final ImageSource? source = await showDialog<ImageSource>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Select Source'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, ImageSource.camera),
            child: Text('Camera'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, ImageSource.gallery),
            child: Text('Gallery'),
          ),
        ],
      ),
    );

    if (source == null) return;

    if (mediaType == MediaType.image) {
      await pickImage(source);
    } else {
      await pickVideo(source);
    }
  }

  Future<void> pickImage(ImageSource source) async {
    final picker = ImagePicker();
    final image = await picker.pickImage(source: source);

    if (image != null) {
      // Clear any existing video
      await disposeVideo();

      setState(() {
        selectedImage = File(image.path);
        selectedVideo = null;
        currentMediaType = MediaType.image;
        isLoading = true;
        statusMessage = "Detecting objects in image...";
        results = [];
        imageWidth = 0;
        imageHeight = 0;
      });

      await detectInImage();
    }
  }

  Future<void> pickVideo(ImageSource source) async {
    final picker = ImagePicker();

    try {
      final video = await picker.pickVideo(
        source: source,
        maxDuration: Duration(minutes: 5), // Limit video duration for better performance
      );

      if (video != null) {
        // Check if file exists and is accessible
        final file = File(video.path);
        if (!await file.exists()) {
          setState(() {
            statusMessage = "Selected video file is not accessible.";
          });
          return;
        }

        // Clear any existing image
        setState(() {
          selectedImage = null;
          selectedVideo = file;
          currentMediaType = MediaType.video;
          isLoading = true;
          statusMessage = "Loading video...";
          results = [];
          imageWidth = 0;
          imageHeight = 0;
        });

        await initializeVideo();
      }
    } catch (e) {
      setState(() {
        statusMessage = "Error picking video: $e";
        isLoading = false;
      });
    }
  }

  Future<void> initializeVideo() async {
    try {
      await disposeVideo();

      // Add a small delay to ensure proper cleanup
      await Future.delayed(Duration(milliseconds: 100));

      videoController = VideoPlayerController.file(selectedVideo!);

      // Set video player options for better compatibility
      videoController!.setVolume(0.0); // Mute by default

      await videoController!.initialize();

      // Check if the controller is still valid after initialization
      if (videoController != null && videoController!.value.isInitialized) {
        setState(() {
          imageWidth = videoController!.value.size.width.toInt();
          imageHeight = videoController!.value.size.height.toInt();
          isLoading = false;
          statusMessage = "Video loaded. Click play to start detection.";
        });

        // Listen for video state changes
        videoController!.addListener(_videoListener);
      } else {
        throw Exception("Video controller failed to initialize properly");
      }
    } catch (e) {
      print('Video initialization error: $e');
      setState(() {
        isLoading = false;
        statusMessage = "Error loading video: $e. Try selecting a different video file.";
      });
      await disposeVideo(); // Clean up on error
    }
  }

  void _videoListener() {
    if (videoController!.value.isPlaying && !isVideoProcessing) {
      startVideoDetection();
    } else if (!videoController!.value.isPlaying && isVideoProcessing) {
      stopVideoDetection();
    }
  }

  void startVideoDetection() {
    if (detectionTimer != null) return;

    setState(() {
      isVideoProcessing = true;
      statusMessage = "Processing video frames...";
    });

    // Process frames every 200ms (5 FPS detection rate)
    detectionTimer = Timer.periodic(Duration(milliseconds: 200), (timer) {
      if (!videoController!.value.isPlaying) {
        timer.cancel();
        return;
      }
      detectCurrentVideoFrame();
    });
  }

  void stopVideoDetection() {
    detectionTimer?.cancel();
    detectionTimer = null;
    setState(() {
      isVideoProcessing = false;
      statusMessage = "Video paused. Detection stopped.";
    });
  }

  Future<void> detectCurrentVideoFrame() async {
    if (isDetecting || videoController == null || !videoController!.value.isInitialized) {
      return;
    }

    setState(() {
      isDetecting = true;
    });

    try {
      // Capture current frame as bytes
      final Uint8List? frameBytes = await captureVideoFrame();

      if (frameBytes != null) {
        final detectionResults = await yolo!.predict(frameBytes);

        List<dynamic> processedResults = [];
        if (detectionResults['boxes'] != null) {
          for (var detection in detectionResults['boxes']) {
            String className;
            var classField = detection['class'];

            if (classField is String) {
              className = classField;
            } else if (classField is int) {
              className = classField < cocoLabels.length
                  ? cocoLabels[classField]
                  : 'Unknown (class $classField)';
            } else {
              className = 'Unknown';
            }

            processedResults.add({
              'class': className,
              'confidence': detection['confidence'] ?? 0.0,
              'box': detection['box'] ?? {},
              'x1': detection['x1'] ?? 0.0,
              'y1': detection['y1'] ?? 0.0,
              'x2': detection['x2'] ?? 0.0,
              'y2': detection['y2'] ?? 0.0,
            });
          }
        }

        setState(() {
          results = processedResults;
          statusMessage = results.isEmpty
              ? "No objects detected in current frame"
              : "Found ${results.length} objects in current frame";
        });
      }
    } catch (e) {
      print('Video frame detection error: $e');
    } finally {
      setState(() {
        isDetecting = false;
      });
    }
  }

  Future<Uint8List?> captureVideoFrame() async {
    try {
      if (videoController == null || !videoController!.value.isInitialized) {
        return null;
      }

      // Get current playback position
      final position = videoController!.value.position;

      // Generate thumbnail at current position
      final uint8list = await VideoThumbnail.thumbnailData(
        video: selectedVideo!.path,
        imageFormat: ImageFormat.PNG,
        timeMs: position.inMilliseconds,
        quality: 100,
      );

      return uint8list;
    } catch (e) {
      print('Error capturing video frame: $e');
      return null;
    }
  }

  Future<void> detectInImage() async {
    if (selectedImage == null) return;

    try {
      final imageBytes = await selectedImage!.readAsBytes();

      final ui.Image imageInfo = await getImageInfo(imageBytes);
      imageWidth = imageInfo.width;
      imageHeight = imageInfo.height;

      final detectionResults = await yolo!.predict(imageBytes);

      List<dynamic> processedResults = [];
      if (detectionResults['boxes'] != null) {
        for (var detection in detectionResults['boxes']) {
          String className;
          var classField = detection['class'];

          if (classField is String) {
            className = classField;
          } else if (classField is int) {
            className = classField < cocoLabels.length
                ? cocoLabels[classField]
                : 'Unknown (class $classField)';
          } else {
            className = 'Unknown';
          }

          processedResults.add({
            'class': className,
            'confidence': detection['confidence'] ?? 0.0,
            'box': detection['box'] ?? {},
            'x1': detection['x1'] ?? 0.0,
            'y1': detection['y1'] ?? 0.0,
            'x2': detection['x2'] ?? 0.0,
            'y2': detection['y2'] ?? 0.0,
          });
        }
      }

      setState(() {
        results = processedResults;
        isLoading = false;
        statusMessage = results.isEmpty
            ? "No objects detected in this image"
            : "Detection complete! Found ${results.length} objects";
      });
    } catch (e) {
      setState(() {
        isLoading = false;
        statusMessage = "Error during detection: $e";
      });
    }
  }

  Future<void> disposeVideo() async {
    detectionTimer?.cancel();
    detectionTimer = null;

    if (videoController != null) {
      try {
        videoController!.removeListener(_videoListener);
        if (videoController!.value.isInitialized) {
          await videoController!.pause();
        }
        await videoController!.dispose();
      } catch (e) {
        print('Error disposing video controller: $e');
      }
      videoController = null;
    }

    if (mounted) {
      setState(() {
        isVideoProcessing = false;
      });
    }
  }

  Widget buildMediaDisplay() {
    if (currentMediaType == MediaType.image && selectedImage != null) {
      return buildImageDisplay();
    } else if (currentMediaType == MediaType.video && selectedVideo != null) {
      return buildVideoDisplay();
    } else {
      return buildPlaceholder();
    }
  }

  Widget buildImageDisplay() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey[300]!),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Stack(
              children: [
                Image.file(
                  selectedImage!,
                  fit: BoxFit.contain,
                  width: constraints.maxWidth,
                  height: constraints.maxHeight,
                ),
                if (results.isNotEmpty && imageWidth > 0 && imageHeight > 0)
                  CustomPaint(
                    size: Size(constraints.maxWidth, constraints.maxHeight),
                    painter: BoundingBoxPainter(
                      results.cast<Map<String, dynamic>>(),
                      imageWidth,
                      imageHeight,
                      constraints.maxWidth,
                      constraints.maxHeight,
                      // isVideo: false, // Explicitly mark as image
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget buildVideoDisplay() {
    if (videoController == null || !videoController!.value.isInitialized) {
      return Container(
        width: double.infinity,
        height: 300,
        decoration: BoxDecoration(
          color: Colors.grey[100],
          border: Border.all(color: Colors.grey[300]!),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey[300]!),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Stack(
              children: [
                // Video with BoxFit.contain behavior
                Container(
                  width: constraints.maxWidth,
                  height: constraints.maxHeight,
                  child: FittedBox(
                    fit: BoxFit.contain,
                    child: SizedBox(
                      width: videoController!.value.size.width,
                      height: videoController!.value.size.height,
                      child: VideoPlayer(videoController!),
                    ),
                  ),
                ),
                if (results.isNotEmpty && imageWidth > 0 && imageHeight > 0)
                  CustomPaint(
                    size: Size(constraints.maxWidth, constraints.maxHeight),
                    painter: BoundingBoxPainter(
                      results.cast<Map<String, dynamic>>(),
                      imageWidth,
                      imageHeight,
                      constraints.maxWidth,
                      constraints.maxHeight,
                      // isVideo: false, // Now we can use the same logic as images!
                    ),
                  ),
                // Video controls overlay
                Positioned(
                  bottom: 10,
                  left: 10,
                  child: FloatingActionButton(
                    mini: true,
                    onPressed: () {
                      if (videoController!.value.isPlaying) {
                        videoController!.pause();
                      } else {
                        videoController!.play();
                      }
                    },
                    child: Icon(
                      videoController!.value.isPlaying ? Icons.pause : Icons.play_arrow,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget buildPlaceholder() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.grey[100],
        border: Border.all(color: Colors.grey[300]!),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              currentMediaType == MediaType.video ? Icons.videocam : Icons.image,
              size: 64,
              color: Colors.grey[400],
            ),
            SizedBox(height: 8),
            Text(
              currentMediaType == MediaType.video ? 'No video selected' : 'No image selected',
              style: TextStyle(
                color: Colors.grey[600],
                fontSize: 16,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('YOLO Object Detection'),
        backgroundColor: Colors.blue[700],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // Status message
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue[200]!),
              ),
              child: Text(
                statusMessage,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
            ),

            SizedBox(height: 20),

            // Media dimensions display
            if ((selectedImage != null || selectedVideo != null) && imageWidth > 0 && imageHeight > 0)
              Container(
                width: double.infinity,
                padding: EdgeInsets.all(12),
                margin: EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.green[50],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.green[200]!),
                ),
                child: Text(
                  '${currentMediaType == MediaType.video ? 'Video' : 'Image'} Dimensions: ${imageWidth}x${imageHeight} pixels',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Colors.green[700],
                  ),
                  textAlign: TextAlign.center,
                ),
              ),

            // Media display
            Expanded(
              flex: 3,
              child: buildMediaDisplay(),
            ),

            SizedBox(height: 20),

            // Action button
            Container(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: (yolo != null && !isLoading) ? pickMedia : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue[700],
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: isLoading
                    ? Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    ),
                    SizedBox(width: 12),
                    Text('Processing...', style: TextStyle(fontSize: 16)),
                  ],
                )
                    : Text(
                  'Pick Media & Detect Objects',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
            ),

            SizedBox(height: 20),

            // Results section
            if (results.isNotEmpty)
              Expanded(
                flex: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Detection Results (${results.length} objects):',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 8),
                    Expanded(
                      child: ListView.builder(
                        itemCount: results.length,
                        itemBuilder: (context, index) {
                          final detection = results[index];
                          final className = detection['class'] ?? 'Unknown';
                          final confidence = detection['confidence'] ?? 0.0;

                          return Card(
                            margin: EdgeInsets.only(bottom: 8),
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor: Colors.blue[700],
                                child: Text(
                                  '${index + 1}',
                                  style: TextStyle(color: Colors.white),
                                ),
                              ),
                              title: Text(
                                className,
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                              subtitle: Text(
                                'Confidence: ${(confidence * 100).toStringAsFixed(1)}%',
                              ),
                              trailing: Container(
                                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: _getConfidenceColor(confidence),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  '${(confidence * 100).toStringAsFixed(0)}%',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              )
            else if ((selectedImage != null || selectedVideo != null) && !isLoading)
              Container(
                padding: EdgeInsets.all(20),
                child: Text(
                  'No objects detected.',
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.grey[600],
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Color _getConfidenceColor(double confidence) {
    if (confidence >= 0.8) return Colors.green;
    if (confidence >= 0.6) return Colors.orange;
    return Colors.red;
  }

  @override
  void dispose() {
    detectionTimer?.cancel();
    disposeVideo();
    yolo?.dispose();
    super.dispose();
  }
}

class BoundingBoxPainter extends CustomPainter {
  final List<Map<String, dynamic>> results;
  final int originalImageWidth;
  final int originalImageHeight;
  final double displayWidth;
  final double displayHeight;

  BoundingBoxPainter(
      this.results,
      this.originalImageWidth,
      this.originalImageHeight,
      this.displayWidth,
      this.displayHeight,
      );

  @override
  void paint(Canvas canvas, Size size) {
    if (originalImageWidth == 0 || originalImageHeight == 0) return;

    double imageAspectRatio = originalImageWidth / originalImageHeight;
    double containerAspectRatio = displayWidth / displayHeight;

    double scaleX, scaleY;
    double offsetX = 0, offsetY = 0;

    if (imageAspectRatio > containerAspectRatio) {
      scaleX = displayWidth / originalImageWidth;
      scaleY = scaleX;
      offsetY = (displayHeight - (originalImageHeight * scaleY)) / 2;
    } else {
      scaleY = displayHeight / originalImageHeight;
      scaleX = scaleY;
      offsetX = (displayWidth - (originalImageWidth * scaleX)) / 2;
    }

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    for (var result in results) {
      final x1 = (result['x1'] ?? 0.0).toDouble();
      final y1 = (result['y1'] ?? 0.0).toDouble();
      final x2 = (result['x2'] ?? 0.0).toDouble();
      final y2 = (result['y2'] ?? 0.0).toDouble();

      final scaledX1 = (x1 * scaleX) + offsetX;
      final scaledY1 = (y1 * scaleY) + offsetY;
      final scaledX2 = (x2 * scaleX) + offsetX;
      final scaledY2 = (y2 * scaleY) + offsetY;

      final className = result['class'] ?? 'Unknown';
      final confidence = (result['confidence'] ?? 0.0) * 100;
      final label = '$className ${confidence.toStringAsFixed(1)}%';

      if (confidence >= 80) {
        paint.color = Colors.green;
      } else if (confidence >= 50) {
        paint.color = Colors.orange;
      } else {
        paint.color = Colors.red;
      }

      final rect = Rect.fromLTRB(scaledX1, scaledY1, scaledX2, scaledY2);
      canvas.drawRect(rect, paint);

      final textPainter = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.bold,
            shadows: [
              Shadow(
                offset: Offset(1, 1),
                blurRadius: 2,
                color: Colors.black54,
              ),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      final labelRect = Rect.fromLTWH(
        scaledX1,
        scaledY1 - textPainter.height - 4,
        textPainter.width + 8,
        textPainter.height + 4,
      );

      final labelPaint = Paint()..color = paint.color;
      canvas.drawRect(labelRect, labelPaint);

      textPainter.paint(canvas, Offset(scaledX1 + 4, scaledY1 - textPainter.height - 2));
    }
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => true;
}