library firestore_collection;

import 'dart:async';
import 'dart:developer';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:collection/collection.dart';
import 'package:sorted_list/sorted_list.dart';

export 'package:sorted_list/sorted_list.dart';

class FirestoreCollection {
  final CollectionReference collection;
  final bool initializeOnStart;
  final Query query;
  final Function(DocumentSnapshot) onDocumentChange;
  final Function(String) onItemRemoved;
  final Function(DocumentSnapshot, DocumentSnapshot) customCompare;
  final int offset;
  final String orderField;
  final Map<String, dynamic> fakeRemoveMap;
  final Function(Map<String, dynamic>, DocumentSnapshot) shouldUpdate;
  final dynamic orderStartValue;
  final dynamic orderEndValue;

  SortedList<DocumentSnapshot> _documentsList;

  // selection
  List<String> _selectedDocuments = [];
  List<String> get selecteds => _selectedDocuments;
  bool isSelected(String id) => _selectedDocuments.contains(id);
  void select(String id) => _selectedDocuments.add(id);
  void deSelect(String id) => _selectedDocuments.remove(id);

  bool _endOfList = false;

  final bool serverOnly;
  final bool live;
  final bool descending;

  bool _fetching = false;
  bool get fetching => _fetching;

  bool _initialized = false;
  bool get initialized => _initialized;

  StreamSubscription<QuerySnapshot> sub;

  SortedList<DocumentSnapshot> get documents => _documentsList;
  int get length => _documentsList.length;

  StreamController<SortedList<DocumentSnapshot>> _stream =
      StreamController<SortedList<DocumentSnapshot>>();

  Stream<SortedList<DocumentSnapshot>> get stream => _stream.stream;

  FirestoreCollection({
    this.collection,
    this.initializeOnStart = true,
    this.orderStartValue,
    this.orderEndValue,
    this.onDocumentChange,
    this.onItemRemoved,
    this.customCompare,
    this.orderField,
    // TODO: multiple query support
    // TODO: merge this field with collection field
    this.query,
    this.live = false,
    this.serverOnly = true,
    // TODO: Ascending query support
    this.descending = true,
    this.offset,
    this.fakeRemoveMap,
    this.shouldUpdate,
  })  : assert(collection != null, "Collection reference can not be null."),
        assert(query != null, "Query can not be null."),
        assert(orderField != null, "Order fild can not be null."),
        assert(descending, "Ascending query is not supported yet."),
        assert(offset != null, "Offset can not be null.") {
    restart();
  }

  void dispose() {
    sub?.cancel();
    _stream?.close();
  }

  void _insert(DocumentSnapshot document) {
    _documentsList.removeWhere((DocumentSnapshot doc) {
      var contains = doc.id == document.id;
      if (contains) {
        onDocumentChange(document);
      }
      return contains;
    });
    _documentsList.add(document);
  }

  Future<void> nextPage() async {
    if (_fetching) {
      return null;
    }
    if (_endOfList) {
      return null;
    }
    _fetching = true;
    int fetchedCount = 0;
    if (serverOnly) {
      QuerySnapshot serverQS = await query
          .where(orderField, isLessThan: _lastFetched())
          .limit(offset - fetchedCount)
          .orderBy(orderField, descending: descending)
          .get(GetOptions(source: Source.server));
      fetchedCount += serverQS.docs.length;
      log("only server fetched count $fetchedCount");
      newPage(serverQS);
    } else {
      QuerySnapshot cacheQS = await query
          .where(orderField, isLessThan: _lastFetched())
          .limit(offset)
          .orderBy(orderField, descending: descending)
          .get(GetOptions(source: Source.cache));
      fetchedCount += cacheQS.docs.length;
      log("cache fetched count $fetchedCount");
      newPage(cacheQS);

      if (fetchedCount != offset) {
        QuerySnapshot serverQS = await query
            .where(orderField, isLessThan: _lastFetched())
            .limit(offset - fetchedCount)
            .orderBy(orderField, descending: descending)
            .get(GetOptions(source: Source.server));
        fetchedCount += serverQS.docs.length;
        log("cache-after server fetched count ${serverQS.docs.length}");
        newPage(serverQS);
      }
    }
    _initialized = true;
    _fetching = false;
    if (fetchedCount < offset) {
      _endOfList = true;
    }
  }

  void newPage(QuerySnapshot querySnapshot) {
    querySnapshot.docs.forEach((document) {
      _insert(document);
    });
    _stream.add(documents);
  }

  dynamic lastMap;
  void collectionListener() {
    if (!live) {
      log("not live collection");
      return null;
    }
    if (sub != null) {
      log("already collection listener");
      return null;
    }
    log("starting collection listener");
    sub = query
        .where(orderField, isGreaterThan: _newestFetched())
        .orderBy(orderField, descending: descending)
        .snapshots(includeMetadataChanges: true)
        .listen((QuerySnapshot qs) {
      qs.docChanges.forEach((DocumentChange change) async {
        if (lastMap != null) {
          dynamic now = change.doc.data();
          if (DeepCollectionEquality.unordered().equals(lastMap, now)) {
            log("already processed");
            return null;
          }
        }
        lastMap = change.doc.data();
        if (shouldUpdate != null ? !shouldUpdate(lastMap, change.doc) : false) {
          log("removed doc updated");
          return null;
        }
        _insert(change.doc);
        _stream.add(documents);
      });
    });
  }

  dynamic _lastFetched() {
    if (_documentsList.isEmpty) {
      return orderStartValue;
    } else {
      return _documentsList.last.data()[orderField];
    }
  }

  dynamic _newestFetched() {
    if (_documentsList.isEmpty) {
      return orderEndValue;
    } else {
      return _documentsList.first.data()[orderField];
    }
  }

  String topDocumentID({String ifAbsent = ""}) {
    if (_documentsList.isEmpty) {
      return ifAbsent;
    } else {
      return _documentsList.first.id;
    }
  }

  Future<void> removeIndex(int index) async {
    DocumentSnapshot removed = _documentsList.removeAt(index);
    await _removeOperation(removed.id);
    _stream.add(documents);
  }

  Future<void> removeID(String documentID, {Function onRemoved}) async {
    _documentsList.removeWhere((DocumentSnapshot doc) => doc.id == documentID);
    await _removeOperation(documentID, onRemoved: onRemoved);
    _stream.add(documents);
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
    wb.commit().then((value) {
      //_callOnEachChunks?.call(0);
    });
  }

  Future<void> removeSelecteds() async {
    log("removeSelecteds");
    int i = 0;
    WriteBatch wb = FirebaseFirestore.instance.batch();
    _selectedDocuments.forEach((documentID) async {
      _documentsList.removeWhere(
        (DocumentSnapshot doc) => doc.id == documentID,
      );
      i++;
      if (fakeRemoveMap == null) {
        wb.delete(collection.doc(documentID));
      } else {
        log("fakemap" + fakeRemoveMap.toString());
        wb.update(collection.doc(documentID), fakeRemoveMap);
      }
      if (i == 50) {
        await wb.commit();
        log("remove part complated");
        wb = FirebaseFirestore.instance.batch();
      }
    });
    await wb.commit();
    selecteds.clear();
    _stream.add(documents);
    log("remove all complated");
  }

  Future<void> _removeOperation(String documentID, {Function onRemoved}) async {
    if (fakeRemoveMap == null) {
      await collection.doc(documentID).delete();
    } else {
      await collection.doc(documentID).update(fakeRemoveMap);
    }
    onRemoved?.call();
    onItemRemoved?.call(documentID);
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
        log("catch error");
      });
    } catch (e) {
      log("$e no cache");
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

  Future<void> restart() async {
    _endOfList = false;
    _documentsList = SortedList<DocumentSnapshot>(
      customCompare ?? timeCompare,
    );
    if (initializeOnStart) {
      await nextPage();
      collectionListener();
    }
  }

  int timeCompare(a, b) {
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
