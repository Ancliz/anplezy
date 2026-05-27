import '../providers/download_provider.dart';
import 'app_logger.dart';

class OfflineModeUtils {
  const OfflineModeUtils._();

  static const initializationTimeout = Duration(seconds: 10);

  static Future<bool> initialize(DownloadProvider downloadProvider, {required String logContext}) async {
    try {
      await downloadProvider.ensureInitialized().timeout(initializationTimeout);
      return true;
    } catch (error, stackTrace) {
      appLogger.w('Offline mode initialization failed during $logContext', error: error, stackTrace: stackTrace);
      return false;
    }
  }
}
