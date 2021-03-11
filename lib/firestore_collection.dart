library firestore_collection;

import 'dart:async';
import 'dart:developer';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:rxdart/rxdart.dart';

class FirestoreCollection {
  FirestoreCollection({
    this.collection,
    this.initializeOnStart = true,
    // TODO: merge this field with collection field
    List<Query> queryList,
    this.queryOrder,
    this.live = false,
    this.serverOnly = true,
    this.includeMetadataChanges = true,
    this.ignoreRemovedUpdate = false,
    this.keepDuplicatedDocs = true,
    this.offset,
    this.onNewPage,
    this.onDocumentChanged,
    this.onItemRemoved,
    this.fakeRemoveMap,
    this.shouldUpdate,
  })  : assert(collection != null, 'Collection reference can not be null.'),
        assert(queryOrder != null, 'QueryOrder can not be null.'),
        assert(offset != null, 'Offset can not be null.'),
        assert((queryList?.isNotEmpty ?? false),
            'queryList can not be empty or null') {
    log('firestore_collection: $hashCode. created.');
    _ql = queryList;
    _init();
    if (initializeOnStart) {
      restart();
    }
  }

  final CollectionReference collection;
  final bool initializeOnStart;
  List<Query> _ql;
  final QueryOrder queryOrder;
  final bool live;
  final bool serverOnly;
  final bool includeMetadataChanges;
  final bool ignoreRemovedUpdate;
  final bool keepDuplicatedDocs;
  final int offset;
  final Function(int) onNewPage;
  final Function(DocumentSnapshot) onDocumentChanged;
  final Function(String) onItemRemoved;
  final Map<String, dynamic> fakeRemoveMap;
  final Function(DocumentSnapshot, DocumentSnapshot) shouldUpdate;

  Map<int, bool> _endOfCollectionMap = {};
  bool _fetching = false;
  bool get fetching => _fetching;
  bool _initialized = false;
  bool get initialized => _initialized;

  // documents
  Map<int, List<DocumentSnapshot>> _docsList;
  List<DocumentSnapshot> _displayDocs;

  List<DocumentSnapshot> get documents => _displayDocs ?? _docsList[0];
  int get length => _displayDocs?.length ?? _docsList[0].length;

  // selection
  List<String> _selectedDocuments = [];
  List<String> get selectedDocs => _selectedDocuments;
  bool isSelected(String id) => _selectedDocuments.contains(id);
  void select(String id) => _selectedDocuments.add(id);
  void unSelect(String id) => _selectedDocuments.remove(id);

  // listener
  List<StreamSubscription<QuerySnapshot>> _subs;

  // stream
  StreamController<List<DocumentSnapshot>> _streamController =
      BehaviorSubject();
  Stream<List<DocumentSnapshot>> get stream => _streamController?.stream;

  bool get hasDisplayList =>
      queryOrder.displayCompare != null || _ql.length > 1;
  bool get hasDisplayCompare => queryOrder.displayCompare != null;

  void _init() {
    _docsList = {};
    for (var i = 0; i < _ql.length; i++) {
      _docsList[i] = [];
    }
    _subs = [];
    if (hasDisplayList) {
      _displayDocs = [];
    }
  }

  Future<void> restart({
    bool notifyWithEmptyList = false,
    List<Query> newQueryList,
  }) async {
    if (newQueryList != null) _ql = newQueryList;
    for (var s in _subs) await s.cancel();
    _init();
    _endOfCollectionMap.clear();
    if (notifyWithEmptyList) _streamController.add(documents);
    await nextPage();
    await _collectionListener();
  }

  Future<void> dispose() async {
    for (var s in _subs) await s.cancel();
    await _streamController?.close();
    log('firestore_collection: $hashCode. disposed.');
  }

  void _insertDoc(Query _q, DocumentSnapshot document) {
    _docsList[_ql.indexOf(_q)].removeWhere((DocumentSnapshot doc) {
      return doc.id == document.id;
    });
    if (hasDisplayList) {
      _displayDocs.removeWhere((DocumentSnapshot doc) {
        return doc.id == document.id;
      });
    }
    _docsList[_ql.indexOf(_q)].add(document);
    _docsList[_ql.indexOf(_q)].sort(compare);
    if (hasDisplayList) {
      _displayDocs.add(document);
      if (hasDisplayCompare) _displayDocs.sort(queryOrder.displayCompare);
    }
    _streamController?.add(documents);
    onDocumentChanged?.call(document);
  }

  void _insertPage(Query _q, QuerySnapshot querySnapshot) {
    _docsList[_ql.indexOf(_q)].addAll(querySnapshot.docs);

    if (hasDisplayList) {
      // TODO: better impl?
      if (!keepDuplicatedDocs) {
        querySnapshot.docs.forEach((document) {
          _displayDocs.removeWhere((DocumentSnapshot doc) {
            return doc.id == document.id;
          });
        });
      }
      _displayDocs.addAll(querySnapshot.docs);
      if (hasDisplayCompare) _displayDocs.sort(queryOrder.displayCompare);
    }

    _streamController?.add(documents);
    onNewPage?.call(querySnapshot.docs.length);
  }

  Future<void> nextPage() async {
    for (Query q in _ql) {
      await _nextPageInternal(q);
    }
  }

  Future<void> _nextPageInternal(Query _q) async {
    if (_fetching) {
      log('already fetching');
      return;
    }
    if (_endOfCollectionMap[_ql.indexOf(_q)] ?? false) {
      log('can not fetch anymore. end of the collection');
      return;
    }
    _fetching = true;
    int fetchedCount = 0;
    if (serverOnly) {
      QuerySnapshot serverQS = await _q
          .where(queryOrder.orderField, isLessThan: _lastFetched(_q))
          .where(queryOrder.orderField, isGreaterThan: queryOrder?.lastValue)
          .limit(offset - fetchedCount)
          .orderBy(queryOrder.orderField, descending: queryOrder.descending)
          .get(GetOptions(source: Source.server));
      fetchedCount += serverQS.docs.length;
      log('server fetched count: ${serverQS.docs.length}. total: $fetchedCount. [only-server]');
      _insertPage(_q, serverQS);
    } else {
      QuerySnapshot cacheQS = await _q
          .where(queryOrder.orderField, isLessThan: _lastFetched(_q))
          .where(queryOrder.orderField, isGreaterThan: queryOrder?.lastValue)
          .limit(offset)
          .orderBy(queryOrder.orderField, descending: queryOrder.descending)
          .get(GetOptions(source: Source.cache));
      fetchedCount += cacheQS.docs.length;
      log('cache fetched count: ${cacheQS.docs.length}. total: $fetchedCount. [cache-first]');
      _insertPage(_q, cacheQS);

      if (fetchedCount != offset) {
        QuerySnapshot serverQS = await _q
            .where(queryOrder.orderField, isLessThan: _lastFetched(_q))
            .where(queryOrder.orderField, isGreaterThan: queryOrder?.lastValue)
            .limit(offset - fetchedCount)
            .orderBy(queryOrder.orderField, descending: queryOrder.descending)
            .get(GetOptions(source: Source.server));
        fetchedCount += serverQS.docs.length;
        log('server fetched count: ${serverQS.docs.length}. total: $fetchedCount. [cache-first]');
        _insertPage(_q, serverQS);
      }
    }
    _initialized = true;
    _fetching = false;
    if (fetchedCount < offset) {
      log('reached end of the collection');
      _endOfCollectionMap[_ql.indexOf(_q)] = true;
    }
  }

  Future<void> _collectionListener() async {
    if (!live) {
      log('not live collection: $hashCode.');
      return;
    }
    for (var q in _ql) _collectionListenerInternal(q);
  }

  void _collectionListenerInternal(Query _q) {
    log('starting collection listener: ${_q.hashCode}');
    var _sub = _q
        .where(queryOrder.orderField, isGreaterThan: _newestFetched(_q))
        .orderBy(queryOrder.orderField, descending: queryOrder.descending)
        .snapshots(includeMetadataChanges: includeMetadataChanges)
        .listen((QuerySnapshot qs) {
      qs.docChanges.forEach((DocumentChange change) async {
        log('changed: ${change.doc.id}. type: ${change.type}. exist: ${change.doc.exists}.');
        if (change.type == DocumentChangeType.removed) {
          log('removed document change.');
          if (!ignoreRemovedUpdate) _removeDoc(change.doc.id);
          return;
        }
        if (shouldUpdate?.call(change.doc, change.doc) ?? true) {
          _insertDoc(_q, change.doc);
          return;
        }
        log('does not updated by custom function.');
      });
    });
    _subs.add(_sub);
  }

  dynamic _lastFetched(Query _q) {
    if (_docsList[_ql.indexOf(_q)]?.isEmpty ?? true) {
      return;
    } else {
      return _docsList[_ql.indexOf(_q)].last.data()[queryOrder.orderField];
    }
  }

  dynamic _newestFetched(Query _q) {
    if (_docsList[_ql.indexOf(_q)]?.isEmpty ?? true) {
      return queryOrder.lastValue;
    } else {
      return _docsList[_ql.indexOf(_q)].first.data()[queryOrder.orderField];
    }
  }

  Future<void> removeID(String documentID) async {
    await _removeOperation(documentID);
    _removeDoc(documentID);
  }

  Future<void> silentRemoveID(String documentID) async {
    _removeDoc(documentID);
  }

  Future<void> removeSelecteds() async {
    await removeList(selectedDocs);
    selectedDocs.clear();
  }

  Future<void> removeList(List<String> removeList) async {
    WriteBatch wb = FirebaseFirestore.instance.batch();
    int batchLenght = 1;
    List<String> removedDocs = [];

    void removeBatch() {
      _docsList.values.forEach((_d) {
        _d.removeWhere((doc) => removedDocs.contains(doc.id));
      });
      _displayDocs.removeWhere((doc) => removedDocs.contains(doc.id));
      removedDocs.clear();
    }

    removeList.forEach((docID) async {
      removedDocs.add(docID);
      if (fakeRemoveMap == null) {
        wb.delete(collection.doc(docID));
      } else {
        wb.update(collection.doc(docID), fakeRemoveMap);
      }
      if (removedDocs.length == 20) {
        await wb.commit();
        removeBatch();
        log('$batchLenght. batch removed.');
        batchLenght = batchLenght + 1;
        wb = FirebaseFirestore.instance.batch();
      }
    });

    await wb.commit();
    removeBatch();
    log('$batchLenght. batch removed.');
    _streamController?.add(documents);
    log('remove list complated');
  }

  Future<void> _removeOperation(String documentID) async {
    if (fakeRemoveMap == null) {
      await collection.doc(documentID).delete();
    } else {
      await collection.doc(documentID).update(fakeRemoveMap);
    }
    onItemRemoved?.call(documentID);
  }

  Future<void> _removeDoc(String documentID) async {
    _docsList.values.forEach((_d) {
      _d.removeWhere((DocumentSnapshot doc) => doc.id == documentID);
    });
    _displayDocs?.removeWhere((DocumentSnapshot doc) => doc.id == documentID);
    _streamController?.add(documents);
  }

  List<String> getEachFieldValueWithKey(String fieldName) {
    Map<String, DocumentSnapshot> returnMap = {};
    _docsList.values.forEach((_d) {
      _d.forEach((element) {
        if (element.data().containsKey(fieldName)) {
          returnMap.putIfAbsent(element.data()[fieldName], () => element);
        }
      });
    });
    return returnMap.keys.toList();
  }

  List<DocumentSnapshot> docsHasAll(Map<String, dynamic> keyValues) {
    List<DocumentSnapshot> returnMap = [];
    _docsList.values.forEach((_d) {
      _d.forEach((element) {
        bool _insert = false;
        keyValues.forEach((key, value) {
          if (element.data()[key] == value) {
            _insert = true;
          }
        });
        if (_insert) {
          returnMap.insert(0, element);
        }
      });
    });
    return returnMap;
  }

  int compare(DocumentSnapshot a, DocumentSnapshot b) {
    dynamic fieldA = a?.data()[queryOrder.orderField];
    dynamic fieldB = b?.data()[queryOrder.orderField];

    if (fieldA == null) {
      return 1;
    }
    if (fieldB == null) {
      return -1;
    }

    // Descending compare
    return fieldB.compareTo(fieldA);
  }
}

class QueryOrder {
  QueryOrder({
    // TODO: Ascending query support
    this.orderField,
    this.lastValue,
    this.descending = true,
    this.displayCompare,
  })  : assert(orderField != null, 'Order field can not be null.'),
        assert(descending, 'Ascending query is not supported yet.');

  final String orderField;
  final dynamic lastValue;
  final bool descending;
  final int Function(DocumentSnapshot, DocumentSnapshot) displayCompare;
}
