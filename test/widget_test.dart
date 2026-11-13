// Kept in the repo so `flutter create .` does not add its default counter test.
import 'package:flutter_test/flutter_test.dart';
import 'package:kassasysteem/models.dart';

void main() {
  test('euro formatting', () {
    expect(euro(259), '€ 2,59');
  });
}
