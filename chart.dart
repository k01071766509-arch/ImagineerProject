import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_charts/charts.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: const ChartPage(),
    );
  }
}

class ChartPage extends StatelessWidget {
  const ChartPage({super.key});

  @override
  Widget build(BuildContext context) {
    final List<ChartData> chartData = [
      ChartData('Jan', 35),
      ChartData('Feb', 28),
      ChartData('Mar', 34),
      ChartData('Apr', 32),
      ChartData('May', 40),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Votes'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: SfCartesianChart(
          primaryXAxis: CategoryAxis(),
          series: <ChartSeries>[
            ColumnSeries<ChartData, String>(
              dataSource: chartData,
              xValueMapper: (ChartData data, _) => data.month,
              yValueMapper: (ChartData data, _) => data.vote,
            ),
          ],
        ),
      ),
    );
  }
}

class ChartData {
  final String month;
  final double vote;

  ChartData(this.month, this.vote);
}
