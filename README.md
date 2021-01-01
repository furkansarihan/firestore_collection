# firestore_collection

## This package is used in production but It doesn't provide any warranty. So, be careful with your **data**!

Firestore extension with cache-first pagination and stream builder support.

<p align="center">
  <img src="https://github.com/azazadev/firestore_collection/tree/master/assets/screen.gif" height="500px">
</p>

## Features
- Cache-first query support.
- Easy to use with StreamBuilder.
- Pagination support.
- Collection listener support. For documents which has **greater** value related to order field.
- Remove document-list with BatchWrite.
- Select documents to remove.
- Fake **remove** operation with **document update**.
- Custom compare function support for ordering list as desired in ListView.

## Usage

Initialize a FirestoreCollection

``` Dart
FirestoreCollection fireCollection = FirestoreCollection(
    collection: FirebaseFirestore.instance
        .collection('posts')
        .doc('post_id')
        .collection("comments"),
    initializeOnStart: true, // first page will be fetched immediately
    offset: 15, // page size
    serverOnly: false, // cache first
    live: true, // notifies to newest docs
    query: FirebaseFirestore.instance
        .collection('posts')
        .doc('post_id')
        .collection("comments"),
    queryOrder: QueryOrder(
        orderField: 'timestamp',
    ),
);
```

Use it with StreamBuilder

``` Dart
StreamBuilder(
    stream: fireCollection.stream,
    builder: (context, AsyncSnapshot<List<DocumentSnapshot>> snapshot) {
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

Don't forget to dispose

``` Dart
await fireCollection.dispose();
```