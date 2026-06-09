import 'package:get/get.dart';
import 'package:logger/logger.dart';

class LoggerService extends GetxService {
  late final Logger _logger;

  @override
  void onInit() {
    super.onInit();
    _logger = Logger(
      printer: PrettyPrinter(
        methodCount: 1,
        errorMethodCount: 5,
        lineLength: 100,
        colors: true,
        printEmojis: false,
      ),
    );
  }

  void d(String msg) => _logger.d(msg);
  void i(String msg) => _logger.i(msg);
  void w(String msg) => _logger.w(msg);
  void e(String msg, [Object? error, StackTrace? st]) =>
      _logger.e(msg, error: error, stackTrace: st);
}
