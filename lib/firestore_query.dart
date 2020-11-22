import 'package:cloud_firestore/cloud_firestore.dart';

extension FirestoreQueryExtension on Query {
  Future<QuerySnapshot> stream() async {
    try {
      QuerySnapshot qs = await this.get(GetOptions(source: Source.cache));
      if (qs.docs.isEmpty) return this.get(GetOptions(source: Source.server));
      return qs;
    } catch (_) {
      return this.get(GetOptions(source: Source.server));
    }
  }
}
