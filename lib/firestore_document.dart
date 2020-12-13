import 'package:cloud_firestore/cloud_firestore.dart';

extension FirestoreDocumentExtension on DocumentReference {
  Future<DocumentSnapshot> stream() async {
    try {
      DocumentSnapshot ds = await this.get(GetOptions(source: Source.cache));
      if (ds == null) return this.get(GetOptions(source: Source.server));
      return ds;
    } catch (_) {
      return this.get(GetOptions(source: Source.server));
    }
  }
}
