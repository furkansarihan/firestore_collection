import 'package:cloud_firestore/cloud_firestore.dart';

extension FirestoreQueryExtension on Query {
  Future<QuerySnapshot> cacheFirstGet([Duration timeout]) async {
    QuerySnapshot ds = await cacheGet();
    if (ds == null) return serverGet(timeout);
    return ds;
  }

  Future<QuerySnapshot> cacheGet() async {
    try {
      return await this.get(GetOptions(source: Source.cache));
    } catch (e) {
      return null;
    }
  }

  Future<QuerySnapshot> serverGet([Duration timeout]) async {
    try {
      return await this.get(GetOptions(source: Source.server)).timeout(
            timeout ?? const Duration(seconds: 8),
            onTimeout: () => null,
          );
    } catch (e) {
      return null;
    }
  }
}
