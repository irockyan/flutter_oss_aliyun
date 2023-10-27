import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_oss_aliyun/src/auth_mixin.dart';
import 'package:flutter_oss_aliyun/src/client_api.dart';
import 'package:flutter_oss_aliyun/src/extension/date_extension.dart';
import 'package:flutter_oss_aliyun/src/extension/file_extension.dart';
import 'package:flutter_oss_aliyun/src/model/callback.dart';
import 'package:flutter_oss_aliyun/src/model/request.dart';
import 'package:flutter_oss_aliyun/src/model/request_option.dart';
import 'package:flutter_oss_aliyun/src/model/response.dart';
import 'package:xml/xml.dart';

import 'extension/option_extension.dart';
import 'http_mixin.dart';
import 'model/asset_entity.dart';
import 'model/auth.dart';
import 'model/enums.dart';
import 'util/dio_client.dart';
import 'package:path/path.dart' as path2;

class AliyunOssPart {
  int partNumber;
  String etag;
  int start;
  int end;
  int uploadedLength;
  AliyunOssPart(this.partNumber, this.etag,
      {required this.start, required this.end, required this.uploadedLength});
}

class AliyunOssPartConfig {
  /// 分块大小
  int partSize;

  /// 并发数
  int concurrentNumber;

  /// 重试次数
  int leftRetryNumber;
  AliyunOssPartConfig(
      {this.partSize = 1024 * 1024,
      this.concurrentNumber = 10,
      this.leftRetryNumber = 3});
}

class Client with AuthMixin, HttpMixin implements ClientApi {
  static Client? _instance;

  factory Client() => _instance!;

  final String endpoint;
  final String bucketName;

  List<Future<AliyunOssPart>> futureParts = [];

  /// 原始切片数据
  List<AliyunOssPart> originParts = [];
  var theUploadId = "";

  /// objectName
  String _objectName = "";

  // 上传配置
  PutRequestOption? _option;

  /// 文件总大小
  int _contentLength = 0;

  /// 文件总大小
  String _filePath = "";

  /// 分片配置
  AliyunOssPartConfig partConfig = AliyunOssPartConfig();

  /// 正在进行中的上传切片
  List<AliyunOssPart> uploadingParts = [];

  /// 当前状态
  var status = AliyunOssUploadStatus.prepare;

  static late Dio _dio;

  Client._({
    required this.endpoint,
    required this.bucketName,
  });

  static Client init({
    String? stsUrl,
    required String ossEndpoint,
    required String bucketName,
    FutureOr<Auth> Function()? authGetter,
    Dio? dio,
  }) {
    assert(stsUrl != null || authGetter != null);
    _dio = dio ?? RestClient.getInstance();

    final authGet = authGetter ??
        () async {
          final response = await _dio.get<dynamic>(stsUrl!);
          return Auth.fromJson(response.data!);
        };
    _instance = Client._(endpoint: ossEndpoint, bucketName: bucketName)
      ..authGetter = authGet;
    _instance?._objectName = stsUrl!;
    return _instance!;
  }

  /// get object(file) from oss server
  /// [fileKey] is the object name from oss
  /// [bucketName] is optional, we use the default bucketName as we defined in Client
  @override
  Future<Response<dynamic>> getObject(
    String fileKey, {
    String? bucketName,
    CancelToken? cancelToken,
    ProgressCallback? onReceiveProgress,
  }) async {
    final String bucket = bucketName ?? this.bucketName;
    final Auth auth = await getAuth();

    final String url = "https://$bucket.$endpoint/$fileKey";
    final HttpRequest request = HttpRequest.get(url);
    auth.sign(request, bucket, fileKey);

    return _dio.get(
      request.url,
      cancelToken: cancelToken,
      options: Options(headers: request.headers),
      onReceiveProgress: onReceiveProgress,
    );
  }

  /// get signed url from oss server
  /// [fileKey] is the object name from oss
  /// [bucketName] is optional, we use the default bucketName as we defined in Client
  /// [expireSeconds] is optional, default expired time are 60 seconds
  @override
  Future<String> getSignedUrl(
    String fileKey, {
    String? bucketName,
    int expireSeconds = 60,
  }) async {
    final String bucket = bucketName ?? this.bucketName;
    final Auth auth = await getAuth();
    final int expires = DateTime.now().secondsSinceEpoch() + expireSeconds;

    final String url = "https://$bucket.$endpoint/$fileKey";
    final Map<String, dynamic> params = {
      "OSSAccessKeyId": auth.accessKey,
      "Expires": expires,
      "Signature": auth.getSignature(expires, bucket, fileKey),
      "security-token": auth.encodedToken
    };
    final HttpRequest request = HttpRequest.get(url, parameters: params);

    return request.url;
  }

  /// get signed url from oss server
  /// [fileKeys] list of object name from oss
  /// [bucketName] is optional, we use the default bucketName as we defined in Client
  /// [expireSeconds] is optional, default expired time are 60 seconds
  @override
  Future<Map<String, String>> getSignedUrls(
    List<String> fileKeys, {
    String? bucketName,
    int expireSeconds = 60,
  }) async {
    return {
      for (final String fileKey in fileKeys.toSet())
        fileKey: await getSignedUrl(
          fileKey,
          bucketName: bucketName,
          expireSeconds: expireSeconds,
        )
    };
  }

  /// list objects from oss server
  /// [parameters] parameters for filter, refer to: https://help.aliyun.com/document_detail/31957.html
  @override
  Future<Response<dynamic>> listBuckets(
    Map<String, dynamic> parameters, {
    CancelToken? cancelToken,
    ProgressCallback? onReceiveProgress,
  }) async {
    final Auth auth = await getAuth();

    final String url = "https://$endpoint";
    final HttpRequest request = HttpRequest.get(url, parameters: parameters);

    auth.sign(request, "", "");

    return _dio.get(
      request.url,
      cancelToken: cancelToken,
      options: Options(headers: request.headers),
      onReceiveProgress: onReceiveProgress,
    );
  }

  /// list objects from oss server
  /// [parameters] parameters for filter, refer to: https://help.aliyun.com/document_detail/187544.html
  /// [bucketName] is optional, we use the default bucketName as we defined in Client
  @override
  Future<Response<dynamic>> listObjects(
    Map<String, dynamic> parameters, {
    String? bucketName,
    CancelToken? cancelToken,
    ProgressCallback? onReceiveProgress,
  }) async {
    final String bucket = bucketName ?? this.bucketName;
    final Auth auth = await getAuth();

    final String url = "https://$bucket.$endpoint";
    parameters["list-type"] = 2;
    final HttpRequest request = HttpRequest.get(url, parameters: parameters);

    auth.sign(request, bucket, "");

    return _dio.get(
      request.url,
      cancelToken: cancelToken,
      options: Options(headers: request.headers),
      onReceiveProgress: onReceiveProgress,
    );
  }

  /// get bucket info
  /// [bucketName] is optional, we use the default bucketName as we defined in Client
  @override
  Future<Response<dynamic>> getBucketInfo({
    String? bucketName,
    CancelToken? cancelToken,
    ProgressCallback? onReceiveProgress,
  }) async {
    final String bucket = bucketName ?? this.bucketName;
    final Auth auth = await getAuth();

    final String url = "https://$bucket.$endpoint?bucketInfo";
    final HttpRequest request = HttpRequest.get(url);
    auth.sign(request, bucket, "?bucketInfo");

    return _dio.get(
      request.url,
      cancelToken: cancelToken,
      options: Options(headers: request.headers),
      onReceiveProgress: onReceiveProgress,
    );
  }

  /// get bucket stat
  /// [bucketName] is optional, we use the default bucketName as we defined in Client
  @override
  Future<Response<dynamic>> getBucketStat({
    String? bucketName,
    CancelToken? cancelToken,
    ProgressCallback? onReceiveProgress,
  }) async {
    final String bucket = bucketName ?? this.bucketName;
    final Auth auth = await getAuth();

    final String url = "https://$bucket.$endpoint?stat";
    final HttpRequest request = HttpRequest.get(url);
    auth.sign(request, bucket, "?stat");

    return _dio.get(
      request.url,
      cancelToken: cancelToken,
      options: Options(headers: request.headers),
      onReceiveProgress: onReceiveProgress,
    );
  }

  /// download object(file) from oss server
  /// [fileKey] is the object name from oss
  /// [savePath] is where we save the object(file) that download from oss server
  /// [bucketName] is optional, we use the default bucketName as we defined in Client
  @override
  Future<Response> downloadObject(
    String fileKey,
    String savePath, {
    String? bucketName,
    CancelToken? cancelToken,
    ProgressCallback? onReceiveProgress,
  }) async {
    final String bucket = bucketName ?? this.bucketName;
    final Auth auth = await getAuth();

    final String url = "https://$bucket.$endpoint/$fileKey";
    final HttpRequest request = HttpRequest.get(url);
    auth.sign(request, bucket, fileKey);

    return await _dio.download(
      request.url,
      savePath,
      cancelToken: cancelToken,
      options: Options(headers: request.headers),
      onReceiveProgress: onReceiveProgress,
    );
  }

  /// upload object(file) to oss server
  /// [fileData] is the binary data that will send to oss server
  /// [bucketName] is optional, we use the default bucketName as we defined in Client
  @override
  Future<Response<dynamic>> putObject(
    List<int> fileData,
    String fileKey, {
    CancelToken? cancelToken,
    PutRequestOption? option,
  }) async {
    final String bucket = option?.bucketName ?? bucketName;
    final Auth auth = await getAuth();

    final MultipartFile multipartFile = MultipartFile.fromBytes(
      fileData,
      filename: fileKey,
    );
    final Callback? callback = option?.callback;

    final Map<String, dynamic> internalHeaders = {
      'content-type': contentType(fileKey),
      'content-length': multipartFile.length,
      'x-oss-forbid-overwrite': option.forbidOverride,
      'x-oss-object-acl': option.acl,
      'x-oss-storage-class': option.storage,
    };
    final Map<String, dynamic> externalHeaders = option?.headers ?? {};
    final Map<String, dynamic> headers = {
      ...internalHeaders,
      if (callback != null) ...callback.toHeaders(),
      ...externalHeaders,
    };

    final String url = "https://$bucket.$endpoint/$fileKey";
    final HttpRequest request = HttpRequest.put(url, headers: headers);
    auth.sign(request, bucket, fileKey);

    return _dio.put(
      request.url,
      data: multipartFile.chunk(),
      cancelToken: cancelToken,
      options: Options(headers: request.headers),
      onSendProgress: option?.onSendProgress,
      onReceiveProgress: option?.onReceiveProgress,
    );
  }

  /// upload object(file) to oss server
  /// [fileData] is the binary data that will send to oss server
  /// [position] next position that append to, default value is 0.
  @override
  Future<Response<dynamic>> appendObject(
    List<int> fileData,
    String fileKey, {
    CancelToken? cancelToken,
    PutRequestOption? option,
    int? position,
  }) async {
    final String bucket = option?.bucketName ?? bucketName;
    final Auth auth = await getAuth();

    final MultipartFile multipartFile = MultipartFile.fromBytes(
      fileData,
      filename: fileKey,
    );

    final Map<String, dynamic> internalHeaders = {
      'content-type': contentType(fileKey),
      'content-length': multipartFile.length,
      'x-oss-object-acl': option.acl,
      'x-oss-storage-class': option.storage,
    };
    final Map<String, dynamic> externalHeaders = option?.headers ?? {};
    final Map<String, dynamic> headers = {
      ...internalHeaders,
      ...externalHeaders
    };

    final String url =
        "https://$bucket.$endpoint/$fileKey?append&position=${position ?? 0}";
    final HttpRequest request = HttpRequest.post(url, headers: headers);
    auth.sign(request, bucket, "$fileKey?append&position=${position ?? 0}");

    return _dio.post(
      request.url,
      data: multipartFile.chunk(),
      cancelToken: cancelToken,
      options: Options(headers: request.headers),
      onSendProgress: option?.onSendProgress,
      onReceiveProgress: option?.onReceiveProgress,
    );
  }

  /// upload object(file) to oss server
  /// [filepath] is the filepath of the File that will send to oss server
  /// [bucketName] is optional, we use the default bucketName as we defined in Client
  @override
  Future<Response<dynamic>> putObjectFile(
    String filepath, {
    PutRequestOption? option,
    CancelToken? cancelToken,
    String? fileKey,
  }) async {
    final String bucket = option?.bucketName ?? bucketName;
    final String filename = fileKey ?? filepath.split('/').last;
    final Auth auth = await getAuth();

    final MultipartFile multipartFile = await MultipartFile.fromFile(
      filepath,
      filename: filename,
    );

    final Callback? callback = option?.callback;

    final Map<String, dynamic> internalHeaders = {
      'content-type': contentType(filename),
      'content-length': multipartFile.length,
      'x-oss-forbid-overwrite': option.forbidOverride,
      'x-oss-object-acl': option.acl,
      'x-oss-storage-class': option.storage,
    };

    final Map<String, dynamic> externalHeaders = option?.headers ?? {};
    final Map<String, dynamic> headers = {
      ...internalHeaders,
      if (callback != null) ...callback.toHeaders(),
      ...externalHeaders
    };

    final String url = "https://$bucket.$endpoint/$filename";
    final HttpRequest request = HttpRequest.put(url, headers: headers);

    auth.sign(request, bucket, filename);

    return _dio.put(
      request.url,
      data: multipartFile.finalize(),
      options: Options(headers: request.headers),
      cancelToken: cancelToken,
      onSendProgress: option?.onSendProgress,
      onReceiveProgress: option?.onReceiveProgress,
    );
  }

  /// upload object(files) to oss server
  /// [assetEntities] is list of files need to be uploaded to oss
  /// [bucketName] is optional, we use the default bucketName as we defined in Client
  @override
  Future<List<Response<dynamic>>> putObjectFiles(
    List<AssetFileEntity> assetEntities, {
    CancelToken? cancelToken,
  }) async {
    final uploads = assetEntities.map((fileEntity) {
      return putObjectFile(
        fileEntity.filepath,
        fileKey: fileEntity.filename,
        cancelToken: cancelToken,
        option: fileEntity.option,
      );
    }).toList();
    return await Future.wait(uploads);
  }

  /// upload object(files) to oss server
  /// [assetEntities] is list of files need to be uploaded to oss
  /// [bucketName] is optional, we use the default bucketName as we defined in Client
  @override
  Future<List<Response<dynamic>>> putObjects(
    List<AssetEntity> assetEntities, {
    CancelToken? cancelToken,
  }) async {
    final uploads = assetEntities.map((file) {
      return putObject(
        file.bytes,
        file.filename,
        cancelToken: cancelToken,
        option: file.option,
      );
    }).toList();
    return await Future.wait(uploads);
  }

  /// get object metadata
  @override
  Future<Response<dynamic>> getObjectMeta(
    String fileKey, {
    CancelToken? cancelToken,
    String? bucketName,
  }) async {
    final String bucket = bucketName ?? this.bucketName;
    final Auth auth = await getAuth();

    final String url = "https://$bucket.$endpoint/$fileKey";
    final HttpRequest request = HttpRequest(url, 'HEAD', {}, {});
    auth.sign(request, bucket, fileKey);

    return _dio.head(
      request.url,
      cancelToken: cancelToken,
      options: Options(headers: request.headers),
    );
  }

  /// copy object
  @override
  Future<Response<dynamic>> copyObject(
    CopyRequestOption option, {
    CancelToken? cancelToken,
  }) async {
    final String sourceBucketName = option.sourceBucketName ?? bucketName;
    final String sourceFileKey = option.sourceFileKey;
    final String copySource = "/$sourceBucketName/$sourceFileKey";

    final String targetBucketName = option.targetBucketName ?? sourceBucketName;
    final String targetFileKey = option.targetFileKey ?? sourceFileKey;

    final Map<String, dynamic> internalHeaders = {
      'content-type': contentType(targetFileKey),
      'x-oss-copy-source': copySource,
      'x-oss-forbid-overwrite': option.forbidOverride,
      'x-oss-object-acl': option.acl,
      'x-oss-storage-class': option.storage,
    };

    final Map<String, dynamic> externalHeaders = option.headers ?? {};
    final Map<String, dynamic> headers = {
      ...internalHeaders,
      ...externalHeaders
    };

    final Auth auth = await getAuth();

    final String url = "https://$targetBucketName.$endpoint/$targetFileKey";
    final HttpRequest request = HttpRequest.put(url, headers: headers);
    auth.sign(request, targetBucketName, targetFileKey);

    return _dio.put(
      request.url,
      cancelToken: cancelToken,
      options: Options(headers: request.headers),
    );
  }

  /// get all supported regions
  @override
  Future<Response<dynamic>> getAllRegions({
    CancelToken? cancelToken,
  }) async {
    final Auth auth = await getAuth();

    final String url = "https://$endpoint/?regions";
    final HttpRequest request = HttpRequest.get(url);
    auth.sign(request, "", "");

    return _dio.get(
      request.url,
      cancelToken: cancelToken,
      options: Options(headers: request.headers),
    );
  }

  /// get bucket acl
  @override
  Future<Response<dynamic>> getBucketAcl({
    String? bucketName,
    CancelToken? cancelToken,
  }) async {
    final String bucket = bucketName ?? this.bucketName;
    final Auth auth = await getAuth();

    final String url = "https://$bucket.$endpoint/?acl";
    final HttpRequest request = HttpRequest.get(url);
    auth.sign(request, bucket, "?acl");

    return _dio.get(
      request.url,
      cancelToken: cancelToken,
      options: Options(headers: request.headers),
    );
  }

  /// get bucket policy
  @override
  Future<Response<dynamic>> getBucketPolicy({
    String? bucketName,
    CancelToken? cancelToken,
  }) async {
    final String bucket = bucketName ?? this.bucketName;
    final Auth auth = await getAuth();

    final String url = "https://$bucket.$endpoint/?policy";
    final HttpRequest request = HttpRequest.get(url);
    auth.sign(request, bucket, "?policy");

    return _dio.get(
      request.url,
      cancelToken: cancelToken,
      options: Options(headers: request.headers),
    );
  }

  /// delete bucket policy
  @override
  Future<Response<dynamic>> deleteBucketPolicy({
    String? bucketName,
    CancelToken? cancelToken,
  }) async {
    final String bucket = bucketName ?? this.bucketName;
    final Auth auth = await getAuth();

    final String url = "https://$bucket.$endpoint/?policy";
    final HttpRequest request = HttpRequest.delete(url, headers: {
      'content-type': Headers.jsonContentType,
    });
    auth.sign(request, bucket, "?policy");

    return _dio.delete(
      request.url,
      cancelToken: cancelToken,
      options: Options(headers: request.headers),
    );
  }

  /// put bucket policy
  @override
  Future<Response<dynamic>> putBucketPolicy(
    Map<String, dynamic> policy, {
    String? bucketName,
    CancelToken? cancelToken,
  }) async {
    final String bucket = bucketName ?? this.bucketName;
    final Auth auth = await getAuth();

    final String url = "https://$bucket.$endpoint/?policy";
    final HttpRequest request = HttpRequest.put(url, headers: {
      'content-type': Headers.jsonContentType,
    });
    auth.sign(request, bucket, "?policy");

    return _dio.put(
      data: policy,
      request.url,
      cancelToken: cancelToken,
      options: Options(headers: request.headers),
    );
  }

  /// put bucket acl
  @override
  Future<Response<dynamic>> putBucketAcl(
    AclMode aciMode, {
    CancelToken? cancelToken,
    String? bucketName,
  }) async {
    final String bucket = bucketName ?? this.bucketName;
    final Auth auth = await getAuth();

    final String url = "https://$bucket.$endpoint/?acl";
    final HttpRequest request = HttpRequest.put(url, headers: {
      'content-type': Headers.jsonContentType,
      'x-oss-acl': aciMode.content,
    });
    auth.sign(request, bucket, "?acl");

    return _dio.put(
      request.url,
      cancelToken: cancelToken,
      options: Options(headers: request.headers),
    );
  }

  /// get all supported regions
  @override
  Future<Response<dynamic>> getRegion(
    String region, {
    CancelToken? cancelToken,
  }) async {
    final Auth auth = await getAuth();

    final String url = "https://$endpoint/?regions=$region";
    final HttpRequest request = HttpRequest.get(url);
    auth.sign(request, "", "");

    return _dio.get(
      request.url,
      cancelToken: cancelToken,
      options: Options(headers: request.headers),
    );
  }

  /// delete object from oss
  @override
  Future<Response<dynamic>> deleteObject(
    String fileKey, {
    String? bucketName,
    CancelToken? cancelToken,
  }) async {
    final String bucket = bucketName ?? this.bucketName;
    final Auth auth = await getAuth();

    final String url = "https://$bucket.$endpoint/$fileKey";
    final HttpRequest request = HttpRequest.delete(url, headers: {
      'content-type': Headers.jsonContentType,
    });
    auth.sign(request, bucket, fileKey);

    return _dio.delete(
      request.url,
      cancelToken: cancelToken,
      options: Options(headers: request.headers),
    );
  }

  /// delete objects from oss
  @override
  Future<List<Response<dynamic>>> deleteObjects(
    List<String> keys, {
    String? bucketName,
    CancelToken? cancelToken,
  }) async {
    final deletes = keys.map((fileKey) {
      return deleteObject(
        fileKey,
        bucketName: bucketName,
        cancelToken: cancelToken,
      );
    }).toList();

    return await Future.wait(deletes);
  }

  /// 初始化切片上传接口
  /// [return] uploadId
  Future<AliyunOssResponse<String>> initMultipartUpload(
    String filePath, {
    PutRequestOption? option,
    CancelToken? cancelToken,
    String? fileKey,
  }) async {
    final String filename = filePath.split('/').last;
    final String bucket = option?.bucketName ?? bucketName;
    final Map<String, dynamic> internalHeaders = {
      'content-type': contentType(filename),
      'x-oss-forbid-overwrite': option.forbidOverride,
      'x-oss-object-acl': option.acl,
      'x-oss-storage-class': option.storage,
    };

    final Auth auth = await getAuth();

    final Callback? callback = option?.callback;

    final Map<String, dynamic> externalHeaders = option?.headers ?? {};
    final Map<String, dynamic> headers = {
      ...internalHeaders,
      if (callback != null) ...callback.toHeaders(),
      ...externalHeaders
    };

    final String url = "https://$bucket.$endpoint/$filePath?uploads";

    final HttpRequest request = HttpRequest.post(url, headers: headers);

    // 此处是重点，要不然签名不对
    auth.sign(request, bucket, "$filePath?uploads");

    try {
      final result = await _dio.post(request.url,
          options: Options(headers: request.headers), data: "");
      final xml = XmlDocument.parse(result.data ?? "");
      final uploadIdList = xml.findAllElements("UploadId");
      return AliyunOssResponse(uploadIdList.first.innerText,
          code: AliyunOssResponseStatus.success);
    } catch (e) {
      return AliyunOssResponse("",
          code: AliyunOssResponseStatus.fail, msg: "$e");
    }
  }

  /// 上传分片
  Future<AliyunOssPart> uploadPart(String filePath,
      {required int partNumber,
      String? uploadId,
      PutRequestOption? option,
      CancelToken? cancelToken,
      required int start,
      required int end,
      dynamic data}) async {
    final String bucket = option?.bucketName ?? bucketName;
    final String filename = filePath.split('/').last;
    final Auth auth = await getAuth();

    final Callback? callback = option?.callback;

    final Map<String, dynamic> internalHeaders = {
      'content-type': contentType(filename),
      'x-oss-forbid-overwrite': option.forbidOverride,
      'x-oss-object-acl': option.acl,
    };

    final Map<String, dynamic> externalHeaders = option?.headers ?? {};
    final Map<String, dynamic> headers = {
      ...internalHeaders,
      if (callback != null) ...callback.toHeaders(),
      ...externalHeaders
    };

    final String url =
        "https://$bucket.$endpoint/$filePath?partNumber=$partNumber&uploadId=$uploadId";

    final HttpRequest request = HttpRequest.put(url, headers: headers);

    auth.sign(
        request, bucket, "$filePath?partNumber=$partNumber&uploadId=$uploadId");

    try {
      final res = await _dio.put(
        request.url,
        data: data,
        options: Options(headers: request.headers),
        cancelToken: cancelToken,
        onReceiveProgress: (count, total) {
          print("下载中");
        },
      );
      return AliyunOssPart(partNumber, res.headers["etag"]?[0] ?? "",
          start: start, end: end, uploadedLength: 0);
    } catch (e) {
      return AliyunOssPart(partNumber, "",
          start: start, end: end, uploadedLength: 0);
      ;
    }
  }

  /// 上传分片
  Future<AliyunOssPart> _uploadPart(String filePath,
      {required AliyunOssPart part,
      String? uploadId,
      PutRequestOption? option,
      CancelToken? cancelToken,
      dynamic data}) async {
    final end = part.end;
    final start = part.start;
    final partNumber = part.partNumber;
    final String bucket = option?.bucketName ?? bucketName;
    final String filename = filePath.split('/').last;
    final Auth auth = await getAuth();

    final Callback? callback = option?.callback;

    final Map<String, dynamic> internalHeaders = {
      'content-type': contentType(filename),
      'content-length': (end > _contentLength ? _contentLength : end) - start,
      'x-oss-forbid-overwrite': option.forbidOverride,
      'x-oss-object-acl': option.acl,
    };

    final Map<String, dynamic> externalHeaders = option?.headers ?? {};
    final Map<String, dynamic> headers = {
      ...internalHeaders,
      if (callback != null) ...callback.toHeaders(),
      ...externalHeaders
    };

    final String url =
        "https://$bucket.$endpoint/$filePath?partNumber=$partNumber&uploadId=$uploadId";

    final HttpRequest request = HttpRequest.put(url, headers: headers);

    auth.sign(
        request, bucket, "$filePath?partNumber=$partNumber&uploadId=$uploadId");

    try {
      final res = await _dio.put(
        request.url,
        data: data,
        options: Options(
            headers: request.headers,
            sendTimeout: const Duration(milliseconds: 60000),
            receiveTimeout: const Duration(milliseconds: 60000)),
        cancelToken: cancelToken,
        onSendProgress: (count, total) {
          part.uploadedLength = count;
          _calculatorUploadedSize();
        },
        onReceiveProgress: (count, total) {
          print("下载中");
        },
      );
      return AliyunOssPart(partNumber, res.headers["etag"]?[0] ?? "",
          start: start, end: end, uploadedLength: 0);
    } catch (e) {
      return AliyunOssPart(partNumber, "",
          start: start, end: end, uploadedLength: 0);
    }
  }

  Future<String> completeMultipartUpload(String filePath,
      {required List<AliyunOssPart> parts,
      int? partNumber,
      String? uploadId,
      PutRequestOption? option,
      CancelToken? cancelToken,
      dynamic data}) async {
    final sb = StringBuffer();
    sb.write('<CompleteMultipartUpload>');
    for (final part in parts) {
      sb.write("<Part>");
      sb.write("<PartNumber>${part.partNumber}</PartNumber>");
      sb.write("<ETag>${part.etag}</ETag>");
      sb.write("</Part>");
    }
    sb.write('</CompleteMultipartUpload>');
    final xml = XmlDocument.parse(sb.toString()).toXmlString(pretty: true);

    final rawData = Uint8List.fromList(utf8.encode(xml));
    final data = Stream.fromIterable(
        Uint8List.fromList(utf8.encode(xml)).map((e) => [e]));
    final String filename = filePath.split('/').last;
    final String bucket = option?.bucketName ?? bucketName;
    final Map<String, dynamic> internalHeaders = {
      'content-type': contentType(filename),
      'x-oss-forbid-overwrite': option.forbidOverride,
      'x-oss-object-acl': option.acl,
    };

    final Auth auth = await getAuth();

    final Callback? callback = option?.callback;

    final Map<String, dynamic> externalHeaders = option?.headers ?? {};
    final Map<String, dynamic> headers = {
      ...internalHeaders,
      if (callback != null) ...callback.toHeaders(),
      ...externalHeaders
    };

    final String url = "https://$bucket.$endpoint/$filePath?uploadId=$uploadId";
    final HttpRequest request = HttpRequest.post(url, headers: headers);

    // 此处是重点，要不然签名不对
    auth.sign(request, bucket, "$filePath?uploadId=$uploadId");

    try {
      final result = await _dio.post(request.url,
          options: Options(
              headers: request.headers, responseType: ResponseType.plain),
          data: data);
      if (result.statusCode != null &&
          result.statusCode! >= 200 &&
          result.statusCode! <= 300) {
        final xml = XmlDocument.parse(result.data ?? "");
        final uploadIdList = xml.findAllElements("Location");
        return uploadIdList.first.innerText;
      } else {
        return "";
      }
    } catch (e) {
      return "";
    }
  }

  /// 综合上传接口, 使用前需要配置签名等信息
  ///
  /// [return] 返回一个uploadId，用于暂停/重启
  uploadMultipart(
    String filePath, {
    PutRequestOption? option,
    CancelToken? cancelToken,
  }) async {
    _option = option;
    // 首先初始化容器
    originParts = [];
    final result = await initMultipartUpload(_objectName);
    theUploadId = result.data ?? "";
    print("分片初始化成功$theUploadId");
    // 对路径进行切片
    final file = File(filePath);
    // 计算文件大小
    final contentLength = await file.length();
    _contentLength = contentLength;
    print("文件大小$contentLength");

    _filePath = filePath;

    // 进行分片
    originParts = _calculateParts(contentLength);
    print("分片数据$originParts");
    // 进行并发上传
    return await controlConcurrent(originParts);
  }

  /// 控制并发请求
  controlConcurrent(List<AliyunOssPart> parts) async {
    final tempConcurrentNumber = partConfig.concurrentNumber;
    for (var i = 0; i < (parts.length ~/ tempConcurrentNumber) + 1; i++) {
      final temp = readAndUploading(
        _filePath,
        parts: parts,
        left: i * tempConcurrentNumber,
        right: (i + 1) * tempConcurrentNumber > parts.length
            ? parts.length
            : (i + 1) * tempConcurrentNumber,
      );
      await Future.wait(temp);
    }
    return _detectPartUploaded(futureParts);
  }

  /// 进行并发上传
  readAndUploading(
    String filePath, {
    required List<AliyunOssPart> parts,
    required int left,
    required int right,
  }) {
    if (status == AliyunOssUploadStatus.pause) {
      return;
    }
    List<Future<AliyunOssPart>> tempFutures = [];

    for (var i = left; i < right; i++) {
      final e = parts[i];
      dynamic data = File(filePath).openRead(e.start, e.end);
      final future = _uploadPart(
        _objectName,
        part: e,
        uploadId: theUploadId,
        data: data,
      );
      tempFutures.add(future);
      futureParts.add(future);
    }

    return tempFutures;
  }

  /// 计算分片数据
  _calculateParts(int length) {
    List<AliyunOssPart> tempList = [];
    final partLenght = partConfig.partSize;
    for (var i = 0; i < ((length ~/ partLenght) + 1); i++) {
      final partRangeStart = i * partLenght;

      tempList.add(AliyunOssPart(i + 1, "",
          start: partRangeStart,
          end: partRangeStart + partLenght,
          uploadedLength: 0));
    }
    return tempList;
  }

  Future<String?> _detectPartUploaded(
    List<Future<AliyunOssPart>> tempFutureParts,
  ) async {
    final parts = await Future.wait(tempFutureParts);

    for (var element in originParts) {
      final filter = parts.where(
        (p) => p.partNumber == element.partNumber,
      );
      if (filter.isNotEmpty) {
        element.etag = filter.first.etag;
      }
    }

    final tempParts = parts.where((element) => element.etag == "").toList();
    if (tempParts.isEmpty) {
      final res = await _partUploadComplete(originParts);
      return res;
    } else {
      if (partConfig.leftRetryNumber <= 0) {
        return null;
      } else {
        futureParts = [];
        return await Future.delayed(const Duration(milliseconds: 2000),
            () async {
          partConfig.leftRetryNumber--;
          return await await controlConcurrent(tempParts);
        });
      }
    }
  }

  Future<String?> _partUploadComplete(
    List<AliyunOssPart> parts,
  ) async {
    try {
      parts.sort(
        (a, b) => a.partNumber - b.partNumber,
      );
      final res = await completeMultipartUpload(_objectName,
          parts: parts, uploadId: theUploadId);
      return res;
    } catch (e) {
      return null;
    }
  }

  /// 计算上传大小
  _calculatorUploadedSize() {
    final uploadedLength = originParts.fold<int>(
        0, (previousValue, element) => previousValue + element.uploadedLength);
    // var has = uploadedLength;
    // if (has >= _contentLength) {
    //   has = _contentLength;
    // }
    _option?.onSendProgress?.call(uploadedLength, _contentLength);
  }

  /// 暂停上传
  pauseTask() {
    status = AliyunOssUploadStatus.pause;
  }

  /// 继续上传
  resumeTask(
    String uploadId, {
    PutRequestOption? option,
  }) {
    partConfig.leftRetryNumber = 3;
    theUploadId = uploadId;
    _option = option;

    futureParts = [];

    /// 找当前还未上传的parts
    final tempParts =
        originParts.where((element) => element.etag == "").toList();
    return controlConcurrent(tempParts);
  }
}
