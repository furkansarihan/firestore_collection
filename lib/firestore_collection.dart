library firestore_collection;

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:collection/collection.dart';
import 'package:sorted_list/sorted_list.dart';

class FirestoreCollection {
  final CollectionReference collection;
  final bool initialize;
  final Query query;
  final Function(DocumentSnapshot, bool) onDocumentChange;
  final Function(int) onEveryChunk;
  final Function(String) onItemRemoved;
  final Function(DocumentSnapshot, DocumentSnapshot) customCompare;
  final int offset;
  final String orderField;
  final Map<String, dynamic> fakeRemoveMap;
  final Function(Map<String, dynamic>, DocumentSnapshot) shouldUpdate;
  dynamic startTimestamp;
  dynamic endTimestamp;

  SortedList<DocumentSnapshot> _documentsList;

  bool _endOfList = false;

  bool serverOnly;
  bool live;

  bool _fetching = false;

  bool get fetching => _fetching;
  bool initialized = false;

  StreamSubscription<QuerySnapshot> sub;

  SortedList<DocumentSnapshot> get documents => _documentsList;

  FirestoreCollection(this.collection,
      {this.initialize = true,
      this.startTimestamp,
      this.endTimestamp,
      this.onDocumentChange,
      this.onEveryChunk,
      this.onItemRemoved,
      this.customCompare,
      this.orderField,
      this.query,
      this.live = false,
      this.serverOnly = true,
      this.offset,
      this.fakeRemoveMap,
      this.shouldUpdate}) {
    restart();
  }

  int get length => _documentsList.length;

  void dispose() {
    sub?.cancel();
  }

  void _insert(DocumentSnapshot document) {
    _documentsList.removeWhere((DocumentSnapshot doc) => doc.id == document.id);
    _documentsList.add(document);
  }

  void getNewestDocumentChunk() {
    if (_fetching) {
      return null;
    }
    if (_endOfList) {
      return null;
    }
    _fetching = true;
    int fetchedCount = 0;
    bool onEveryChunkFired = false;
    if (!serverOnly) {
      query
          .where(orderField, isLessThan: _lastFetched())
          .limit(offset)
          .orderBy(orderField, descending: true)
          .get(GetOptions(source: Source.cache))
          .then((cacheQS) {
        initialized = true;
        fetchedCount += cacheQS.docs.length;
        print("cache fetched count $fetchedCount");
        cacheQS.docs.forEach((document) {
          _insert(document);
        });
        onEveryChunk?.call(fetchedCount);
        if (fetchedCount < offset) {
          query
              .where(orderField, isLessThan: _lastFetched())
              .limit(offset - fetchedCount)
              .orderBy(orderField, descending: true)
              .get(GetOptions(source: Source.server))
              .then((QuerySnapshot serverQS) {
            initialized = true;
            fetchedCount += serverQS.docs.length;
            print("server fetched count $fetchedCount");
            List<DocumentSnapshot> docs = serverQS.docs;
            docs.forEach((document) {
              _insert(document);
              if (onDocumentChange != null) {
                onDocumentChange(document, false);
              }
            });
            _fetching = false;
            onEveryChunk?.call(fetchedCount);
            if (fetchedCount < offset) {
              _endOfList = true;
            }
            collectionListener();
          }).whenComplete(() {
            _fetching = false;
            onEveryChunk?.call(fetchedCount);
          });
        } else {
          _fetching = false;
          collectionListener();
        }
      }).whenComplete(() {
        _fetching = false;
      });
    } else {
      query
          .where(orderField, isLessThan: _lastFetched())
          .limit(offset - fetchedCount)
          .orderBy(orderField, descending: true)
          .get(GetOptions(source: Source.server))
          .then((QuerySnapshot serverQS) {
        initialized = true;
        fetchedCount += serverQS.docs.length;
        print("$fetchedCount");
        List<DocumentSnapshot> docs = serverQS.docs;
        docs.forEach((document) {
          _insert(document);
          if (onDocumentChange != null) {
            onDocumentChange(document, false);
          }
        });
        _fetching = false;
        onEveryChunkFired = true;
        onEveryChunk?.call(fetchedCount);
        if (fetchedCount < offset) {
          _endOfList = true;
        }
        collectionListener();
      }).whenComplete(() {
        _fetching = false;
        if (!onEveryChunkFired) {
          onEveryChunk?.call(fetchedCount);
        }
      });
    }
  }

  dynamic lastMap;
  void collectionListener() {
    if (!live) {
      print("not live collection");
      return null;
    }
    if (sub != null) {
      print("already collection listener");
      return null;
    }
    print("starting collection listener");
    sub = query
        .where(orderField, isGreaterThan: _newestFetched())
        .orderBy(orderField, descending: true)
        .snapshots(includeMetadataChanges: true)
        .listen((QuerySnapshot qs) {
      qs.docChanges.forEach((DocumentChange change) async {
        if (lastMap != null) {
          dynamic now = change.doc.data();
          if (DeepCollectionEquality.unordered().equals(lastMap, now)) {
            print("already processed");
            return null;
          }
        }
        lastMap = change.doc.data();
        if (shouldUpdate != null ? !shouldUpdate(lastMap, change.doc) : false) {
          print("removed doc updated");
          return null;
        }
        _insert(change.doc);
        onDocumentChange?.call(change.doc, true);
      });
    });
  }

  Future<void> refreshLatest() async {
    await query
        .where(orderField, isGreaterThan: _newestFetched())
        .orderBy(orderField, descending: true)
        .get()
        .then((qs) {
      qs.docChanges.forEach((DocumentChange change) async {
        _insert(change.doc);
        if (onDocumentChange != null) {
          onDocumentChange(change.doc, false);
        }
      });
    });
  }

  dynamic _lastFetched() {
    if (_documentsList.isEmpty) {
      return startTimestamp;
    } else {
      return _documentsList.last.data()[orderField];
    }
  }

  dynamic _newestFetched() {
    if (_documentsList.isEmpty) {
      return endTimestamp ?? Timestamp.fromMillisecondsSinceEpoch(0);
    } else {
      return _documentsList.first.data()[orderField];
    }
  }

  void removeIndex(int index) {
    DocumentSnapshot removed = _documentsList.removeAt(index);
    _removeOperation(removed.id);
    print(removed);
  }

  String topDocumentID({String ifAbsent = ""}) {
    if (_documentsList.isEmpty) {
      return ifAbsent;
    } else {
      return _documentsList.first.id;
    }
  }

  void removeID(String documentID, {Function onRemoved}) {
    _documentsList.removeWhere((DocumentSnapshot doc) => doc.id == documentID);
    _removeOperation(documentID, onRemoved: onRemoved);
  }

  void removeMemoryOnly(String documentID, {Function onRemoved}) {
    _documentsList.removeWhere((DocumentSnapshot doc) => doc.id == documentID);
  }

  void removeAll() {
    int i = 0;
    WriteBatch wb = FirebaseFirestore.instance.batch();
    _documentsList.forEach((document) async {
      i++;
      if (fakeRemoveMap == null) {
        wb.delete(collection.doc(document.id));
      } else {
        wb.update(collection.doc(document.id), fakeRemoveMap);
      }
      if (i == 50) {
        await wb.commit();
        wb = FirebaseFirestore.instance.batch();
      }
    });
    wb.commit().then((value) => onEveryChunk?.call(0));
  }

  void removeList(List<String> removeList) {
    print("removeList");
    int i = 0;
    WriteBatch wb = FirebaseFirestore.instance.batch();
    removeList.forEach((documentID) async {
      _documentsList
          .removeWhere((DocumentSnapshot doc) => doc.id == documentID);
      i++;
      if (fakeRemoveMap == null) {
        wb.delete(collection.doc(documentID));
      } else {
        print("fakemap" + fakeRemoveMap.toString());
        wb.update(collection.doc(documentID), fakeRemoveMap);
      }
      if (i == 50) {
        await wb.commit();
        print("committed");
        wb = FirebaseFirestore.instance.batch();
      }
    });
    wb.commit().then((value) {
      print("committeed");
      onEveryChunk?.call(0);
    });
  }

  void _removeOperation(String documentID, {Function onRemoved}) {
    if (fakeRemoveMap == null) {
      collection.doc(documentID).delete().whenComplete(() {
        onRemoved?.call();
        onItemRemoved?.call(documentID);
      });
    } else {
      collection.doc(documentID).update(fakeRemoveMap).whenComplete(() {
        onRemoved?.call();
        onItemRemoved?.call(documentID);
      });
    }
  }

  void getFromCache(
    String documentID, {
    Source source = Source.cache,
    Function(DocumentSnapshot) onGet,
  }) {
    if (documentID == null || documentID == "") {
      return null;
    }
    DocumentSnapshot doc;
    try {
      query
          .where(FieldPath.documentId, isEqualTo: documentID)
          .limit(1)
          .get(GetOptions(source: source))
          .then((value) {
        if (value.docs.isNotEmpty) {
          doc = value.docs.first;
        }
      }).whenComplete(() {
        if (doc != null) {
          _documentsList.removeWhere(
            (DocumentSnapshot doc) => doc.id == documentID,
          );
          _insert(doc);
          onGet?.call(doc);
        }
      }).catchError((e) {
        print("catch error");
      });
    } catch (e) {
      print("$e no cache");
      onGet?.call(null);
    }
    return null;
  }

  bool containsIdCache(String documentID) {
    return _documentsList.any((element) => element.id == documentID);
  }

  List<DocumentSnapshot> docsHasAll(Map<String, dynamic> keyValues) {
    List<DocumentSnapshot> returnMap = List<DocumentSnapshot>();
    _documentsList.forEach((element) {
      bool _insert = false;
      keyValues.forEach((key, value) {
        if (element.data().containsKey(key)) {
          if (element.data()[key] == value) {
            _insert = true;
          }
        }
      });
      if (_insert) {
        returnMap.insert(0, element);
      }
    });
    return returnMap;
  }

  List<String> getEachFieldValueWithKey(String fieldName) {
    Map<String, DocumentSnapshot> returnMap = Map<String, DocumentSnapshot>();
    _documentsList.forEach((element) {
      if (element.data().containsKey(fieldName)) {
        returnMap.putIfAbsent(element.data()[fieldName], () => element);
      }
    });
    return returnMap.keys.toList();
  }

  void restart() {
    _endOfList = false;
    _documentsList = SortedList<DocumentSnapshot>(customCompare ??
        (a, b) {
          Timestamp tsA = timeFromMap(a.data(), orderField,
              Timestamp.fromMillisecondsSinceEpoch(9999999999999));
          Timestamp tsB = timeFromMap(b.data(), orderField,
              Timestamp.fromMillisecondsSinceEpoch(9999999999999));
          if (tsA == null) {
            return -1;
          }
          if (tsB == null) {
            return 1;
          }
          return tsB.compareTo(tsA);
        });
    if (initialize) {
      getNewestDocumentChunk();
    }
  }

  static Timestamp timeFromMap(
      Map<String, dynamic> map, String key, Timestamp ifAbsent) {
    if (ifAbsent == null) {
      ifAbsent = Timestamp.fromMillisecondsSinceEpoch(0);
    }
    if (map == null) {
      return ifAbsent;
    }
    if (!map.containsKey(key)) {
      return ifAbsent;
    }
    if (!(map[key] is Timestamp)) {
      return ifAbsent;
    }
    if (map[key] == null) {
      return ifAbsent;
    }
    return map[key];
  }
}
