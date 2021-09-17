import 'package:cloud_firestore/cloud_firestore.dart';

extension FirestoreQueryExtension on Query {
  Future<QuerySnapshot?> cacheFirstGet() async {
    QuerySnapshot? ds = await cacheGet();
    if (ds == null) return serverGet();
    return ds;
  }

  Future<QuerySnapshot?> cacheGet() async {
    try {
      return await this.get(GetOptions(source: Source.cache));
    } catch (e) {
      return null;
    }
  }

  Future<QuerySnapshot?> serverGet() async {
    try {
      return await this.get(GetOptions(source: Source.server));
    } catch (e) {
      return null;
    }
  }
}
