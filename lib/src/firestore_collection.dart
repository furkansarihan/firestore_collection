library firestore_collection;

import 'dart:async';
import 'dart:developer';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:rxdart/rxdart.dart';

import 'extensions.dart';

class FirestoreCollection {
  FirestoreCollection({
    required this.collection,
    this.initializeOnStart = true,
    // TODO: merge this field with collection field
    required List<Query> queryList,
    required QueryOrder queryOrder,
    this.live = false,
    this.serverOnly = true,
    this.includeMetadataChanges = true,
    this.ignoreRemovedUpdate = false,
    this.keepDuplicatedDocs = true,
    required int pageSize,
    this.onNewPage,
    this.onDocumentChanged,
    this.onItemRemoved,
    this.onFetchFailed,
    this.fakeRemoveMap,
    this.shouldUpdate,
  }) : assert((queryList.isNotEmpty), 'queryList can not be empty.') {
    log('firestore_collection: $hashCode. created.', name: _name);
    _ql = queryList;
    _qo = queryOrder;
    _pageSize = pageSize;
    _init();
    if (initializeOnStart) {
      restart();
    }
  }

  final CollectionReference collection;
  final bool initializeOnStart;
  late List<Query> _ql;
  late QueryOrder _qo;
  final bool live;
  final bool serverOnly;
  final bool includeMetadataChanges;
  final bool ignoreRemovedUpdate;
  final bool keepDuplicatedDocs;
  late int _pageSize;
  final Function(int)? onNewPage;
  final Function(
    DocumentSnapshot doc,
    DocumentChangeType type,
  )? onDocumentChanged;
  final Function(String)? onItemRemoved;
  final Function(bool initialized)? onFetchFailed;
  final Map<String, dynamic>? fakeRemoveMap;
  final Function(DocumentSnapshot, DocumentSnapshot)? shouldUpdate;

  Map<int, bool> _endOfCollectionMap = {};
  bool _fetching = false;
  bool get fetching => _fetching;
  bool _initialized = false;
  bool get initialized => _initialized;

  bool get endOfCollection {
    for (var value in _endOfCollectionMap.values) {
      if (!value) return false;
    }
    return true;
  }

  // documents
  late Map<int, List<DocumentSnapshot>> _docsList;
  List<DocumentSnapshot>? _displayDocs;

  List<DocumentSnapshot>? get documents => _displayDocs ?? _docsList[0];
  int get length => _displayDocs?.length ?? _docsList[0]!.length;

  // selection
  List<String> _selectedDocuments = [];
  List<String> get selectedDocs => _selectedDocuments;
  bool isSelected(String id) => _selectedDocuments.contains(id);
  void select(String id) => _selectedDocuments.add(id);
  void unSelect(String id) => _selectedDocuments.remove(id);

  // listener
  late List<StreamSubscription<QuerySnapshot>> _subs;

  // stream
  StreamController<List<DocumentSnapshot>?> _streamController =
      BehaviorSubject();
  Stream<List<DocumentSnapshot>?> get stream => _streamController.stream;

  bool get hasDisplayList => _qo.displayCompare != null || _ql.length > 1;
  bool get hasDisplayCompare => _qo.displayCompare != null;

  static String _name = 'firestore_collection';

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

  Future<bool> restart({
    bool notifyWithEmptyList = false,
    List<Query>? newQueryList,
    QueryOrder? newQueryOrder,
  }) async {
    _fetching = false;
    if (newQueryList != null) _ql = newQueryList;
    if (newQueryOrder != null) _qo = newQueryOrder;
    for (var s in _subs) await s.cancel();
    _init();
    _endOfCollectionMap.clear();
    if (notifyWithEmptyList) _streamController.add(documents);
    bool result = await nextPage();
    await _collectionListener();
    return result;
  }

  Future<void> dispose() async {
    for (var s in _subs) await s.cancel();
    await _streamController.close();
    log('firestore_collection: $hashCode. disposed.', name: _name);
  }

  void _insertDoc(
    Query _q,
    DocumentSnapshot document,
    DocumentChangeType type,
  ) {
    _docsList[_ql.indexOf(_q)]!.removeWhere((DocumentSnapshot doc) {
      return doc.id == document.id;
    });
    if (hasDisplayList) {
      _displayDocs!.removeWhere((DocumentSnapshot doc) {
        return doc.id == document.id;
      });
    }
    _docsList[_ql.indexOf(_q)]!.add(document);
    _docsList[_ql.indexOf(_q)]!.sort(compare);
    if (hasDisplayList) {
      _displayDocs!.add(document);
      if (hasDisplayCompare) _displayDocs!.sort(_qo.displayCompare);
    }
    _streamController.add(documents);
    onDocumentChanged?.call(document, type);
  }

  void _insertPage(Query _q, QuerySnapshot querySnapshot) {
    _docsList[_ql.indexOf(_q)]!.addAll(querySnapshot.docs);

    if (hasDisplayList) {
      // TODO: better impl?
      if ((!keepDuplicatedDocs) && _ql.length > 1) {
        querySnapshot.docs.forEach((document) {
          _displayDocs!.removeWhere((DocumentSnapshot doc) {
            return doc.id == document.id;
          });
        });
      }
      _displayDocs!.addAll(querySnapshot.docs);
      if (hasDisplayCompare) _displayDocs!.sort(_qo.displayCompare);
    }

    _streamController.add(documents);
    onNewPage?.call(querySnapshot.docs.length);
    _initialized = true;
  }

  Future<bool> nextPage({int? pageSize}) async {
    bool result = true;
    for (Query q in _ql) {
      result = result && await _nextPageInternal(q, pageSize ?? _pageSize);
    }
    return result;
  }

  Future<bool> _nextPageInternal(Query _q, int pageSize) async {
    if (_fetching) {
      log('already fetching', name: _name);
      return true;
    }
    if (_endOfCollectionMap[_ql.indexOf(_q)] ?? false) {
      log('can not fetch anymore. end of the collection', name: _name);
      return true;
    }
    _fetching = true;
    int fetchedCount = 0;
    if (serverOnly) {
      final lastDoc = _lastFetchedDoc(_q);
      Query _qq = _q.orderBy(
        _qo.orderField,
        descending: _qo.descending,
      );
      if (lastDoc != null) _qq = _qq.startAfterDocument(lastDoc);
      // TODO: start at value

      QuerySnapshot? serverQS =
          await _qq.limit(pageSize - fetchedCount).serverGet();
      if (serverQS == null) {
        log('can not fetch from server', name: _name);
        _fetching = false;
        onFetchFailed?.call(_initialized);
        return false;
      }
      fetchedCount += serverQS.docs.length;
      log(
        'server fetched count: ${serverQS.docs.length}. total: $fetchedCount. [only-server]',
        name: _name,
      );
      _insertPage(_q, serverQS);
    } else {
      final lastDoc = _lastFetchedDoc(_q);
      Query _qq = _q.orderBy(
        _qo.orderField,
        descending: _qo.descending,
      );
      if (lastDoc != null) _qq = _qq.startAfterDocument(lastDoc);

      QuerySnapshot? cacheQS = await _qq.limit(pageSize).cacheGet();
      if (cacheQS == null) {
        log('can not fetch from cache', name: _name);
        _fetching = false;
        onFetchFailed?.call(_initialized);
        return false;
      }
      fetchedCount += cacheQS.docs.length;
      log(
        'cache fetched count: ${cacheQS.docs.length}. total: $fetchedCount. [cache-first]',
        name: _name,
      );
      _insertPage(_q, cacheQS);

      if (fetchedCount != pageSize) {
        final lastDoc = _lastFetchedDoc(_q);
        Query _qq = _q.orderBy(
          _qo.orderField,
          descending: _qo.descending,
        );
        if (lastDoc != null) _qq = _qq.startAfterDocument(lastDoc);

        QuerySnapshot? serverQS =
            await _qq.limit(pageSize - fetchedCount).serverGet();
        if (serverQS == null) {
          log('can not fetch from server - cache first', name: _name);
          _fetching = false;
          onFetchFailed?.call(_initialized);
          return false;
        }
        fetchedCount += serverQS.docs.length;
        log(
          'server fetched count: ${serverQS.docs.length}. total: $fetchedCount. [cache-first]',
          name: _name,
        );
        _insertPage(_q, serverQS);
      }
    }
    _initialized = true;
    _fetching = false;
    if (fetchedCount < pageSize) {
      log('reached end of the collection', name: _name);
      _endOfCollectionMap[_ql.indexOf(_q)] = true;
    }
    return true;
  }

  Future<void> _collectionListener() async {
    if (!live) {
      log('not live collection: $hashCode.', name: _name);
      return;
    }
    for (var q in _ql) _collectionListenerInternal(q);
  }

  void _collectionListenerInternal(Query _q) {
    log('starting collection listener: ${_q.hashCode}', name: _name);
    final firstDoc = _firstFetchedDoc(_q);
    Query _qq = _q.orderBy(
      _qo.orderField,
      descending: _qo.descendingLive,
    );
    if (firstDoc != null && firstDoc.data() != null) {
      final firstData = firstDoc.data() as Map<String, dynamic>;
      if (firstData[_qo.orderField] != null) {
        _qq =
            _qq.where(_qo.orderField, isGreaterThan: firstData[_qo.orderField]);
      }
    }
    var _sub = _qq
        .snapshots(includeMetadataChanges: includeMetadataChanges)
        .listen((QuerySnapshot qs) {
      qs.docChanges.forEach((DocumentChange change) async {
        log(
          'changed: ${change.doc.id}. type: ${change.type}. exist: ${change.doc.exists}.',
          name: _name,
        );
        if (change.type == DocumentChangeType.removed) {
          log('removed document change.', name: _name);
          if (!ignoreRemovedUpdate) _removeDoc(change.doc.id);
          return;
        }
        if (shouldUpdate?.call(change.doc, change.doc) ?? true) {
          _insertDoc(_q, change.doc, change.type);
          return;
        }
        log('does not updated by custom function.', name: _name);
      });
    });
    _subs.add(_sub);
  }

  DocumentSnapshot? _lastFetchedDoc(Query _q) {
    if (_docsList[_ql.indexOf(_q)]?.isEmpty ?? true) {
      return null;
    } else {
      return _docsList[_ql.indexOf(_q)]!.last;
    }
  }

  DocumentSnapshot? _firstFetchedDoc(Query _q) {
    if (_docsList[_ql.indexOf(_q)]?.isEmpty ?? true) {
      return null;
    } else {
      return _docsList[_ql.indexOf(_q)]!.first;
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
      _displayDocs!.removeWhere((doc) => removedDocs.contains(doc.id));
      removedDocs.clear();
    }

    removeList.forEach((docID) async {
      removedDocs.add(docID);
      if (fakeRemoveMap == null) {
        wb.delete(collection.doc(docID));
      } else {
        wb.update(collection.doc(docID), fakeRemoveMap!);
      }
      if (removedDocs.length == 20) {
        await wb.commit();
        removeBatch();
        log('$batchLenght. batch removed.', name: _name);
        batchLenght = batchLenght + 1;
        wb = FirebaseFirestore.instance.batch();
      }
    });

    await wb.commit();
    removeBatch();
    log('$batchLenght. batch removed.', name: _name);
    _streamController.add(documents);
    log('remove list complated', name: _name);
  }

  Future<void> _removeOperation(String documentID) async {
    if (fakeRemoveMap == null) {
      await collection.doc(documentID).delete();
    } else {
      await collection.doc(documentID).update(fakeRemoveMap!);
    }
    onItemRemoved?.call(documentID);
  }

  Future<void> getDoc(String documentID) async {
    final snap = await collection.doc(documentID).get();
    if (!snap.exists) {
      log('requested doc is not exist. id: $documentID', name: _name);
      return;
    }
    _insertDoc(_ql.first, snap, DocumentChangeType.added);
  }

  Future<void> _removeDoc(String documentID) async {
    _docsList.values.forEach((_d) {
      _d.removeWhere((DocumentSnapshot doc) => doc.id == documentID);
    });
    _displayDocs?.removeWhere((DocumentSnapshot doc) => doc.id == documentID);
    _streamController.add(documents);
  }

  List<String?> getEachFieldValueWithKey(String fieldName) {
    Map<String?, DocumentSnapshot> returnMap = {};
    _docsList.values.forEach((_d) {
      _d.forEach((element) {
        if (element[fieldName] != null) {
          returnMap.putIfAbsent(element[fieldName], () => element);
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
          if (element[key] == value) {
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
    dynamic fieldA = a[_qo.orderField];
    dynamic fieldB = b[_qo.orderField];

    if (fieldA == null) {
      return _qo.descending ? 1 : -1;
    }
    if (fieldB == null) {
      return _qo.descending ? -1 : 1;
    }

    return _qo.descending ? fieldB.compareTo(fieldA) : fieldA.compareTo(fieldB);
  }
}

class QueryOrder {
  QueryOrder({
    required this.orderField,
    this.descending = true,
    this.descendingLive = true,
    this.displayCompare,
  });

  final String orderField;
  final bool descending;
  final bool descendingLive;
  final int Function(DocumentSnapshot, DocumentSnapshot)? displayCompare;
}
