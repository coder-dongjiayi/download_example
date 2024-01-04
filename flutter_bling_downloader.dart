library flutter_bling_downloader;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:background_downloader/background_downloader.dart';
import 'package:crypto/crypto.dart';
import 'package:background_downloader/src/database.dart';
import 'package:flutter_mxlogger/flutter_mxlogger.dart';
import 'package:path_provider/path_provider.dart';
export 'package:background_downloader/background_downloader.dart';

typedef TaskDownloadCallback = void Function(
    Task task, TaskStatus status, double progress);

class FlutterBlingDownloader {
  static const String _nameSpace = "downloadSpace";

  late BaseDirectory _baseDirectory;
  late FileDownloader _downloader;

  final Set<String?> _downloadTask = {};
  String? _loggerKey;

  static String _directory = "";

  static String get directory => _directory;

  static Future<void> initialize() async {
    late Directory directory;
    if (Platform.isIOS) {
      directory = await getLibraryDirectory();
    } else {
      directory = await getApplicationSupportDirectory();
    }

    _directory = "${directory.path}/$_nameSpace";
  }

  ///删除下载记录
  static Future<void> deleteDownloadRecord({String? remoteUrl}) async {
    if (remoteUrl?.isEmpty == true) return;
    String taskId = _generateTaskId(remoteUrl!);
    await FileDownloader().database.deleteRecordWithId(taskId);
  }

  /// 获取已下载的本地文件路径 返回null 则本地不存在
  static Future<String?> getLocationPath({String? remoteUrl}) async {
    if (remoteUrl?.isEmpty == true) return null;
    String taskId = _generateTaskId(remoteUrl!);
    TaskRecord? record = await FileDownloader().database.recordForId(taskId);
    if (record == null) return null;
    if (record.status != TaskStatus.complete) return null;
    String filePath = await record.task.filePath();
    return filePath;
  }

  /// 判断一组路径是否已经下载完成，返回未下载完成的远程路径
  static Future<List<String>> exitLocation({List<String?>? taskList}) async {
    if (taskList?.isEmpty == true) {
      return [];
    }
    List<String> list = [];
    for (var task in taskList!) {
      String? location = await getLocationPath(remoteUrl: task);
      if (location == null && task != null) {
        list.add(task);
      }
    }
    return list;
  }

  /// 删除所有下载的资源
  static Future<void> deleteAll() async {
    List<TaskRecord> alRecords = await FileDownloader().database.allRecords();
    for (var element in alRecords) {
      if (element.status == TaskStatus.complete) {
        String filePath = await element.task.filePath();
        File file = File(filePath);
        if (file.existsSync() == true) {
          file.deleteSync();
        }
      }
    }
    await FileDownloader().database.deleteAllRecords();
  }

  /// 用于写日志
  FlutterBlingDownloader({String? loggerKey}) {
    _downloader = FileDownloader();
    _loggerKey = loggerKey;
    if (Platform.isIOS) {
      _baseDirectory = BaseDirectory.applicationLibrary;
    } else {
      _baseDirectory = BaseDirectory.applicationSupport;
    }
  }

  Future<File?> _recordFilePath(TaskRecord? record) async {
    String? filePath = await record?.task.filePath();
    if (filePath != null) {
      File file = File(filePath);
      if (file.existsSync()) return file;
    }
    return null;
  }

  /// 暂停下载
  Future<bool> pause({required String taskUrl}) async {
    String taskId = _generateTaskId(taskUrl);
    TaskRecord? record = await _downloader.database.recordForId(taskId);
    if (record?.task == null) {
      return false;
    }
    if (record!.task is DownloadTask) {
      return _downloader.pause(record.task as DownloadTask);
    }
    return false;
  }

  void pauseBatch({List<String?>? taskList}) async {
    taskList?.forEach((element) {
      if (element != null) {
        pause(taskUrl: element);
      }
    });
  }

  void pauseAll() {
    if (_downloadTask.isEmpty) return;
    _debugLog(msg: "pauseAll()", tag: "暂停所有下载");

    pauseBatch(taskList: _downloadTask.toList());
  }

  Future<void> downloadBatch(
      {List<String?>? taskList,
      void Function(double)? onProgress,
      void Function(String, String)? onError}) async {
    if (taskList != null && taskList.isEmpty == true) return Future.value();

    _debugLog(msg: "$taskList", tag: "批量下载");
    String group = _generateTaskId(taskList?.join(",") ?? "");
    int index = 0;
    int length = taskList!.length;
    double avg = 1 / length;
    _downloadTask.addAll(taskList);
    for (var taskUrl in taskList) {
      await _download(
          group: group,
          taskUrl: taskUrl,
          onProgress: (progress) {
            double p = (progress + index) * avg;
            onProgress?.call(p);
          },
          onError: onError);
      index++;
    }
  }

  Future<String?> download({
    String? taskUrl,
    void Function(TaskStatus)? onStatus,
    void Function(double)? onProgress,
    void Function(String, String)? onError,
  }) {
    return _download(
        taskUrl: taskUrl,
        onError: onError,
        onProgress: onProgress,
        onStatus: onStatus);
  }

  Future<String?> _download({
    String? taskUrl,
    String? group,
    void Function(TaskStatus)? onStatus,
    void Function(double)? onProgress,
    void Function(String, String)? onError,
  }) async {
    if (taskUrl == null || taskUrl.isEmpty == true) return Future.value(null);
    if (taskUrl.substring(0, 4) != "http") return Future.value(null);

    _downloadTask.add(taskUrl);

    Completer<String?> completer = Completer();
    String taskId = _generateTaskId(taskUrl);

    _debugLog(msg: "taskId:$taskId taskUrl:$taskUrl", tag: "开始下载");

    TaskRecord? taskRecord = await _downloader.database.recordForId(taskId);
    if (taskRecord?.status == TaskStatus.complete) {
      final file = await _recordFilePath(taskRecord);
      return file?.path;
    }
    String registerGroup = group ?? "group_$taskId";
    bool result = false;

    if (taskRecord?.status.isNotFinalState == true &&
        taskRecord?.task != null) {
      if(taskRecord?.status == TaskStatus.paused){
        result = await _downloader.resume(taskRecord!.task as DownloadTask);
      }else{
        final task = _addEnqueued(taskUrl: taskUrl, taskId: taskId, registerGroup: registerGroup);
        taskRecord = TaskRecord(task, TaskStatus.enqueued, 0);
        result = await _downloader.enqueue(task);
      }
    } else {
       final task = _addEnqueued(taskUrl: taskUrl, taskId: taskId, registerGroup: registerGroup);
      taskRecord = TaskRecord(task, TaskStatus.enqueued, 0);
      result = await _downloader.enqueue(task);
    }
    if (result == true) {
      _registerCallback(
          record: taskRecord,
          completer: completer,
          onStatus: (status){
            if(status.isFinalState == true){
              _downloader.unregisterCallbacks(group: registerGroup);
            }
          },
          onProgress: onProgress,
          onError: onError);
    }else{
      _debugLog(msg: "进入下载队列失败");
    }

    return completer.future;
  }

  DownloadTask _addEnqueued({required String taskUrl,required String taskId,required String registerGroup}){
    String ex = path.extension(taskUrl);
    DownloadTask task = DownloadTask(
        taskId: taskId,
        url: taskUrl,
        directory: _nameSpace,
        filename: "$taskId$ex",
        group: registerGroup,
        baseDirectory: _baseDirectory,
        updates: Updates.statusAndProgress,
        allowPause: true);
    return task;

  }

  void _registerCallback(
      {required TaskRecord record,
      required Completer<String?> completer,
      void Function(TaskStatus)? onStatus,
      void Function(double)? onProgress,
      void Function(String, String)? onError}) {
    _downloader.registerCallbacks(
        group: record.group,
        taskProgressCallback: (update) {
          _downloadTaskProgress(
              update: update, record: record, onProgress: onProgress);
          _debugLog(
              msg: "progress:${update.progress} taskId:${update.task.taskId} ",
              tag: "下载中");
        },
        taskStatusCallback: (updateTask) async {
          _downloadTaskStatus(
              updateTask: updateTask,
              record: record,
              onError: onError,
              onCompleter: (filePath, error) {
                if (error == null) {
                  completer.complete(filePath);
                  _debugLog(
                      msg:
                          "taskId:${updateTask.task.taskId} filePath:$filePath",
                      tag: "下载完成");
                } else {
                  _debugLog(
                      msg: "taskId:${updateTask.task.taskId} error:$error",
                      tag: "下载失败");
                  completer.complete(null);
                }
              },
              onStatus: onStatus);
        });
  }

  /// 下载状态回调
  void _downloadTaskStatus(
      {required TaskStatusUpdate updateTask,
      required TaskRecord record,
      void Function(TaskStatus)? onStatus,
      void Function(String?, String?)? onCompleter,
      void Function(String, String)? onError}) async {
    if (updateTask.status.isFinalState) {
      _downloadTask.remove(updateTask.task.url);
    }
    if (updateTask.task.taskId == record.taskId) {
      onStatus?.call(updateTask.status);
      if (updateTask.status.isFinalState) {
        _downloadTask.remove(updateTask.task.url);
      }
      if (updateTask.status == TaskStatus.complete) {
        String? filePath = await updateTask.task.filePath();
        onCompleter?.call(filePath, null);
      } else if (updateTask.status == TaskStatus.failed ||
          updateTask.status == TaskStatus.notFound ||
          updateTask.exception != null) {
        String exception =
            "文件下载失败:${updateTask.status} ===> ${updateTask.exception}";
        onError?.call(updateTask.task.url, exception);
        onCompleter?.call(null, exception);
      }
      _debugLog(msg: "status:${updateTask.status}");
      _downloader.database
          .updateRecord(record.copyWith(status: updateTask.status));
    }
  }

  /// 下载进度回调
  void _downloadTaskProgress(
      {required TaskProgressUpdate update,
      required TaskRecord record,
      void Function(double)? onProgress}) {
    if (update.task.taskId == record.taskId && update.progress > 0) {
      onProgress?.call(update.progress);
      _downloader.database
          .updateRecord(record.copyWith(progress: update.progress));
    }
  }

  void _debugLog({required String msg, String? tag}) {
    if (_loggerKey == null) return;
    MXLogger.debugLog(_loggerKey, msg, tag: tag);
  }

  /// 生成下载任务id
  static String _generateTaskId(String input) {
    return md5.convert(utf8.encode(input)).toString();
  }
}
