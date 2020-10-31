import 'package:cloud_firestore/cloud_firestore.dart';

extension FirestoreDocumentExtension on DocumentReference {
  Future<DocumentSnapshot> stream() async {
    try {
      return this.get(GetOptions(source: Source.cache));
    } catch (_) {
      return this.get(GetOptions(source: Source.server));
    }
  }
}
