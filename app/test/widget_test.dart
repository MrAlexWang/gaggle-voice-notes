import 'package:flutter_test/flutter_test.dart';
import 'package:gaggle/ai_client.dart';
import 'package:gaggle/theme.dart';

void main() {
  test('时长格式化', () {
    expect(fmtDurMs(65000), '01:05');
    expect(fmtDurMs(null), '--:--');
    expect(fmtDurMs(0), '--:--');
    expect(fmtDurMs(3723000), '62:03');
  });

  test('时间显示', () {
    final now = DateTime.now().millisecondsSinceEpoch;
    expect(fmtClock(now).startsWith('今天'), true);
  });

  test('录音标题的时间戳格式', () {
    final d = DateTime(2026, 11, 20, 15, 30, 45);
    expect(fmtStamp(d.millisecondsSinceEpoch), '2026-11-20 15:30:45');
  });

  test('AI 标题解析', () {
    expect(AiClient.parseTitle('「产品评审会」'), '产品评审会');
    expect(AiClient.parseTitle('“就医复诊”。'), '就医复诊');
    expect(AiClient.parseTitle('  \n面试复盘 \n多余的'), '面试复盘');
    expect(AiClient.parseTitle(''), '');
  });

  test('AI 推荐问题解析', () {
    expect(
      AiClient.parseQuestions('一句话总结\n转述给别人听\n有哪些值得怀疑的地方'),
      ['一句话总结', '转述给别人听', '有哪些值得怀疑的地方'],
    );
    expect(
      AiClient.parseQuestions('1. 一句话总结\n2、转述给别人听\n'),
      ['一句话总结', '转述给别人听'],
    );
    expect(AiClient.parseQuestions('「核心观点是什么」'), ['核心观点是什么']);
    expect(AiClient.parseQuestions('a,b,c,d', count: 2).length, 2);
  });

  test('AI 标签解析', () {
    expect(AiClient.parseTags('产品评审, 待办'), ['产品评审', '待办']);
    expect(AiClient.parseTags('["会议", "招聘"]'), ['会议', '招聘']);
    expect(AiClient.parseTags('```json\n["面试"]\n```'), ['面试']);
    expect(AiClient.parseTags('#就医、复诊'), ['就医', '复诊']);
    expect(AiClient.parseTags(''), isEmpty);
  });
}
