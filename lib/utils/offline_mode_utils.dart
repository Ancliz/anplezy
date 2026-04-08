import '../providers/download_provider.dart';
import 'app_logger.dart';
import 'connection_constants.dart';

class OfflineModeUtils {
  
  static Future<bool> initialize(
    DownloadProvider downloadProvider, {
    required String logContext,
  }) async {
    try {
      await downloadProvider.ensureInitialized().timeout(ConnectionTimeouts.offlineRetry);
      return true;
    } catch (error, stackTrace) {
      appLogger.w('Offline mode initialization failed during $logContext', error: error, stackTrace: stackTrace);
      return false;
    }
  }
  
}