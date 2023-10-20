import 'package:flutter_oss_aliyun/src/model/enums.dart';

class AliyunOssResponse<T> {
  AliyunOssResponseStatus code;
  String? msg;
  T? data;
  AliyunOssResponse(
    this.data, {
    required this.code,
    this.msg,
  });
}

class AliyunOssUploadPartResponse {
  String etag;
  int partNumber;
  AliyunOssUploadPartResponse({required this.etag, required this.partNumber});
}
