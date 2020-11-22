# firestore_collection

## This package is used in production but It doesn't provide any warranty. So, be careful with your **data**!

Firestore extension with cache-first pagination and stream builder support.

## Features
- cache-first query support
- Pagination with offset lenght
- Collection listener support for **only newest** documents 
- Custom values for query order's start and end.
- Easy to use with StreamBuilder
- Remove document-list with BatchWrite
- Select documents to remove
- Fake **remove** operation with **update**
- Optional display order field rather than query order field

## Usage

Initialize a FirestoreCollection

``` Dart
FirestoreCollection fireCollection = FirestoreCollection(
    FirebaseFirestore.instance
        .collection('posts')
        .doc('post_id')
        .collection("comments"),
    initializeOnStart: true, // first page will fetched immediately
    offset: 15, // page size
    serverOnly: false, // cache first
    live: true, // notifies to newest comments
    query: FirebaseFirestore.instance
        .collection('posts')
        .doc('post_id')
        .collection("comments"),
    orderField: 'timestamp',
);
```

Use it with StreamBuilder

``` Dart
StreamBuilder(
    stream: fireCollection.stream,
    builder: (context, AsyncSnapshot<SortedList<DocumentSnapshot>> snapshot) {
        return ListView.builder(itemBuilder: (context, index) {
            return Text(snapshot.data.elementAt(index).id);
        });
    },
);
```

Fetch next page

``` Dart
fireCollection.nextPage();
```
