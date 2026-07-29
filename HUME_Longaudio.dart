import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: AudioPickerPage(),
    );
  }
}

// ===== 감정 분류 매핑표 =====
const Map<String, String> emotionMap = {
  "joy": "긍정", "happiness": "긍정", "amusement": "긍정",
  "satisfaction": "긍정", "excitement": "긍정", "contentment": "긍정",
  "love": "긍정", "admiration": "긍정", "triumph": "긍정",
  "relief": "긍정", "pride": "긍정", "interest": "긍정",
  "determination": "긍정", "gratitude": "긍정", "sympathy": "긍정",

  "sadness": "부정", "anger": "부정", "fear": "부정",
  "disgust": "부정", "anxiety": "부정", "distress": "부정",
  "embarrassment": "부정", "guilt": "부정", "shame": "부정",
  "disappointment": "부정", "contempt": "부정", "tiredness": "부정",
  "doubt": "부정", "confusion": "부정",

  "calmness": "중립", "concentration": "중립",
  "surprise (positive)": "중립", "surprise_positive": "중립",
  "surprise (negative)": "중립", "surprise_negative": "중립",
  "realization": "중립", "boredom": "중립", "contemplation": "중립",
};

String classifyEmotion(String emotionName) {
  return emotionMap[emotionName.toLowerCase()] ?? "중립";
}

// EVI가 정적 구간마다 턴을 여러 번 나누면서, 같은 내용을 통째로
// 중복해서 다시 보내는 경우가 있습니다 ("AAA" → "AAAAAA" 형태).
// 텍스트가 앞/뒤 절반으로 똑같이 나뉘는 패턴이면, 앞부분만 사용합니다.
String deduplicateRepeatedText(String text) {
  final trimmed = text.trim();
  final len = trimmed.length;
  if (len < 6) return trimmed;

  // 정확히 절반(또는 거의 절반)에서 나눴을 때 앞뒤가 같은지 확인
  for (int i = (len / 2).ceil(); i >= (len * 0.4).floor(); i--) {
    final first = trimmed.substring(0, i).trim();
    final rest = trimmed.substring(i).trim();
    if (first.length >= 4 && rest == first) {
      return first;
    }
  }
  return trimmed;
}

class AudioPickerPage extends StatefulWidget {
  const AudioPickerPage({super.key});

  @override
  State<AudioPickerPage> createState() => _AudioPickerPageState();
}

class _AudioPickerPageState extends State<AudioPickerPage> {

  // ===== 프록시 서버 주소 =====
  static const String proxyServerUrl = "ws://localhost:8080";

  final AudioRecorder _recorder = AudioRecorder();
  WebSocketChannel? _channel;

  bool isRecording = false;
  bool isAnalyzing = false;
  bool isListening = false; // 실제로 마이크 스트림이 시작된 후에만 true
  bool isStopping = false; // 정지 버튼을 중복으로 누르는 것 방지
  String statusMessage = "";
  String resultText = "";
  String _accumulatedText = ""; // 여러 user_message 조각을 합쳐 보관하는 내부 버퍼
  final List<MapEntry<String, double>> _emotionPieces = []; // 조각별 최고 감정 기록
  String topEmotion = "";
  double topScore = 0.0;
  String category = "";

  bool _connectionReady = false;
  StreamSubscription? _audioSubscription;

  @override
  void dispose() {
    _recorder.dispose();
    _channel?.sink.close();
    _audioSubscription?.cancel();
    super.dispose();
  }

  Future<void> startRecording() async {
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      setState(() => statusMessage = "마이크 권한이 없어요.");
      return;
    }

    setState(() {
      isRecording = true;
      isAnalyzing = false;
      statusMessage = "서버에 연결 중...";
      resultText = "";
      _accumulatedText = "";
      _emotionPieces.clear();
      topEmotion = "";
      category = "";
      _connectionReady = false;
    });

    try {
      // 이제 Hume에 직접 연결하지 않고, 우리 프록시 서버에만 연결합니다.
      // API 키/Config ID는 서버(.env)가 알아서 붙여서 Hume에 연결해줍니다.
      final uri = Uri.parse(proxyServerUrl);
      _channel = WebSocketChannel.connect(uri);

      await _channel!.ready;
      debugPrint("프록시 서버 WebSocket 연결 완료");

      _channel!.stream.listen(
            (message) {
          final data = jsonDecode(message);
          _handleMessage(data);
        },
        onError: (error) {
          debugPrint("WebSocket 에러: $error");
          setState(() {
            statusMessage = "에러: $error";
            isRecording = false;
            isAnalyzing = false;
          });
        },
        onDone: () {
          debugPrint("WebSocket 연결 종료됨");
        },
      );

      // chat_metadata 대기 (이 사이에 session_settings가 전송됨)
      int waited = 0;
      while (!_connectionReady && waited < 5000) {
        await Future.delayed(const Duration(milliseconds: 100));
        waited += 100;
      }

      // 실시간 마이크 스트림 시작
      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );

      // 스트림이 실제로 열린 이 시점부터가 진짜 "듣고 있는" 상태입니다.
      setState(() {
        isListening = true;
        statusMessage = "지금부터 말씀해주세요";
      });

      // 침묵 누적 시간(ms). 이 값이 일정 기준을 넘으면, 그 이후의 침묵은
      // 서버로 보내지 않고 건너뜁니다. 사람이 실제로는 몇 초를 쉬든
      // 서버 입장에서는 "연속으로 조용한 시간"이 이 기준을 절대
      // 넘지 않게 되어, Turn Detection이 문장 중간에 잘못 끊는
      // 문제를 원천적으로 막습니다. (말소리는 그대로 다 전송됨)
      int silentMs = 0;
      const int silenceAmplitudeThreshold = 500; // 16bit PCM 기준 (0~32767)
      const int maxAllowedSilenceMs = 1200; // 이보다 길게 조용하면 전송 안 함

      // 마이크 데이터 → 프록시 서버로 실시간 전송 (서버가 Hume으로 다시 중계)
      _audioSubscription = stream.listen((audioData) {
        if (_channel != null && isRecording) {
          // 이 청크가 "조용한지" 평균 진폭으로 판단
          int sum = 0;
          int sampleCount = 0;
          for (int i = 0; i + 1 < audioData.length; i += 2) {
            final sample = (audioData[i] | (audioData[i + 1] << 8)).toSigned(16);
            sum += sample.abs();
            sampleCount++;
          }
          final avgAmplitude = sampleCount > 0 ? sum / sampleCount : 0;
          final chunkMs =
          sampleCount > 0 ? (sampleCount / 16000 * 1000).round() : 100;

          if (avgAmplitude < silenceAmplitudeThreshold) {
            silentMs += chunkMs;
          } else {
            silentMs = 0; // 말소리가 감지되면 침묵 누적 초기화
          }

          if (silentMs > maxAllowedSilenceMs) {
            // 너무 길게 조용한 구간은 전송하지 않고 건너뜀
            return;
          }

          final encoded = base64Encode(audioData);
          _channel!.sink.add(jsonEncode({
            "type": "audio_input",
            "data": encoded,
          }));
        }
      });

    } catch (e) {
      debugPrint("startRecording 에러: $e");
      setState(() {
        statusMessage = "에러: $e";
        isRecording = false;
        isListening = false;
      });
    }
  }

  Future<void> stopRecording() async {
    if (isStopping) return; // 이미 정지 처리 중이면 중복 실행 방지
    isStopping = true;

    // 정지 버튼을 누른 즉시 마이크를 끊지 않습니다.
    // 말이 끝나자마자 버튼을 눌러도 마지막 단어가 잘리지 않도록,
    // 마이크를 계속 열어둔 채로 여유를 준 다음 정지합니다.
    setState(() {
      isListening = false;
      statusMessage = "마무리 중...";
    });

    await Future.delayed(const Duration(milliseconds: 1500));

    // EVI가 "발화가 끝났다"고 확실히 인식하도록, 무음(silence) 데이터를
    // 충분히 길게 전송합니다. Hume Config의 Turn Detection이
    // "3000ms(3초) 이상 조용해야 턴 종료"로 설정되어 있으므로,
    // 그보다 살짝 더 긴 3.5초 분량의 무음을 보내야 턴이 확정됩니다.
    // (이보다 짧게 보내면 EVI가 끝까지 "아직 말하는 중"으로 판단해
    //  user_message 자체가 오지 않는 문제가 생깁니다.)
    if (_channel != null) {
      final silenceChunk = List<int>.filled(3200, 0); // 16bit, 16kHz 기준 약 0.1초 분량
      final encodedSilence = base64Encode(silenceChunk);
      for (int i = 0; i < 35; i++) {
        _channel!.sink.add(jsonEncode({
          "type": "audio_input",
          "data": encodedSilence,
        }));
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }

    setState(() {
      isRecording = false;
      isAnalyzing = true;
      statusMessage = "분석 중... 잠시 기다려주세요.";
    });

    await _recorder.stop();
    _audioSubscription?.cancel();

    // 응답 대기 (10초)
    await Future.delayed(const Duration(seconds: 10));

    await _channel?.sink.close();

    if (topEmotion.isNotEmpty) {
      await _saveToFirestore();
    }

    setState(() {
      isAnalyzing = false;
      isStopping = false;
      statusMessage = topEmotion.isEmpty
          ? "분석 완료 (결과 없음)"
          : "분석 완료 (Firebase 저장됨)";
    });
  }

  Future<void> _saveToFirestore() async {
    try {
      await FirebaseFirestore.instance.collection('emotion_results').add({
        'recognized_text': resultText,
        'top_emotion': topEmotion,
        'top_score': topScore,
        'category': category,
        'timestamp': FieldValue.serverTimestamp(),
      });
      debugPrint("Firestore 저장 완료");
    } catch (e) {
      debugPrint("Firestore 저장 에러: $e");
    }
  }

  void _handleMessage(Map<String, dynamic> data) {
    debugPrint("수신: ${data['type']}");

    final type = data["type"];

    if (type == "chat_metadata") {
      _connectionReady = true;
      debugPrint("chat_metadata 수신 → 연결 준비 완료");

      // EVI에게 오디오 포맷(linear16, 16kHz, mono)을 알려줌.
      // PCM은 헤더가 없는 포맷이라, 이 메시지를 보내지 않으면
      // EVI가 오디오를 해석하지 못해 계속 "no user message"
      // 상태로 남다가 타임아웃됩니다.
      _channel?.sink.add(jsonEncode({
        "type": "session_settings",
        "audio": {
          "sample_rate": 16000,
          "channels": 1,
          "encoding": "linear16",
        },
      }));
      debugPrint("session_settings 전송 완료 (linear16, 16000Hz, mono)");

  
    } else if (type == "user_message") {
      final interim = data["interim"] ?? false;
      if (interim == true) return;

      final content = data["message"]?["content"] ?? "";
      final prosody = data["models"]?["prosody"]?["scores"] as Map<String, dynamic>?;

      if (prosody == null || prosody.isEmpty) {
        debugPrint("prosody 점수 없음");
        return;
      }

      final sorted = prosody.entries.toList()
        ..sort((a, b) => (b.value as num).compareTo(a.value as num));

      final top1 = sorted.first;

      final newPiece = deduplicateRepeatedText(content);
      debugPrint("=== user_message 진단 ===");
      debugPrint("원본 content: [$content] (길이: ${content.length})");
      debugPrint("newPiece: [$newPiece] (길이: ${newPiece.length})");
      debugPrint("병합 전 _accumulatedText: [$_accumulatedText]");

      setState(() {
        // 세 가지 경우를 구분해서 처리합니다:
        // 1) 새 조각이 지금까지 쌓아둔 내용을 통째로 포함(누적 성장) → 새 조각으로 교체
        //    → 같은 발화가 더 완전하게 다시 온 것이므로, 감정 기록도 이 조각 하나로 리셋
        // 2) 지금까지 쌓아둔 내용이 새 조각을 이미 포함(중복/구버전) → 무시
        // 3) 둘 다 아님(정적 이후 완전히 새로운 독립 조각) → 뒤에 이어붙이고, 감정도 추가
        if (newPiece.isEmpty) {
          // 아무 것도 안 함
        } else if (_accumulatedText.isEmpty || newPiece.contains(_accumulatedText)) {
          _accumulatedText = newPiece;
          _emotionPieces
            ..clear()
            ..add(MapEntry(top1.key, (top1.value as num).toDouble()));
        } else if (_accumulatedText.contains(newPiece)) {
          // 이미 더 긴 내용을 갖고 있으므로 무시
        } else {
          _accumulatedText = "$_accumulatedText $newPiece";
          _emotionPieces.add(MapEntry(top1.key, (top1.value as num).toDouble()));
        }

        resultText = _accumulatedText;

        // 정적 이전/이후를 통틀어, 지금까지 나온 조각들 중 가장 점수가 높은
        // 감정을 최종 대표 감정으로 채택합니다 (마지막 조각만 보지 않음).
        if (_emotionPieces.isNotEmpty) {
          final best = _emotionPieces.reduce(
                  (a, b) => a.value >= b.value ? a : b);
          topEmotion = best.key;
          topScore = best.value;
          category = classifyEmotion(best.key);
        }
        debugPrint("병합 후 _accumulatedText: [$_accumulatedText]");
        debugPrint("========================");
      });
    } else if (type == "error") {
      setState(() => statusMessage = "에러: ${data["message"]}");
    }
  }

  Color _categoryColor(String cat) {
    switch (cat) {
      case "긍정": return Colors.green;
      case "부정": return Colors.red;
      default: return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Hume EVI 실시간 분석"),
        centerTitle: true,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // ===== 녹음 버튼 =====
              // 상태는 4단계로 명확히 구분됩니다:
              // 1) 대기 중 (isRecording=false)
              // 2) 연결 중 (isRecording=true, isListening=false, isStopping=false) → 아직 말하면 안 됨
              // 3) 듣는 중 (isListening=true) → 이제 말해도 됨, 누르면 정지 가능
              // 4) 마무리/분석 중 (isStopping=true 또는 isAnalyzing=true) → 버튼 비활성화
              GestureDetector(
                onTap: isAnalyzing || isStopping
                    ? null
                    : isRecording
                    ? (isListening ? stopRecording : null) // 연결 중엔 정지 불가
                    : startRecording,
                child: Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isListening
                        ? Colors.red // 실제로 듣고 있는 중
                        : (isRecording || isAnalyzing || isStopping)
                        ? Colors.grey // 연결 중 / 마무리 중 / 분석 중
                        : const Color(0xFF6C5CE7), // 대기 중
                  ),
                  child: Icon(
                    isListening ? Icons.stop : Icons.mic,
                    color: Colors.white,
                    size: 40,
                  ),
                ),
              ),

              const SizedBox(height: 16),

              Text(
                isListening
                    ? "듣고 있어요... (누르면 종료)"
                    : isRecording
                    ? "연결 중이에요, 잠시만요..."
                    : isAnalyzing
                    ? "분석 중..."
                    : "마이크 버튼을 눌러 시작",
                style: const TextStyle(fontSize: 15, color: Colors.grey),
              ),

              const SizedBox(height: 8),

              if (statusMessage.isNotEmpty)
                Text(
                  statusMessage,
                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                  textAlign: TextAlign.center,
                ),

              const SizedBox(height: 24),

              // ===== 결과 카드 =====
              if (topEmotion.isNotEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.grey[100],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("인식된 텍스트: $resultText",
                          style: const TextStyle(fontSize: 16)),
                      const SizedBox(height: 12),
                      Text("최종 감정: $topEmotion (${topScore.toStringAsFixed(3)})",
                          style: const TextStyle(fontSize: 16)),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: _categoryColor(category).withOpacity(0.15),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          "분류: $category",
                          style: TextStyle(
                            color: _categoryColor(category),
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}