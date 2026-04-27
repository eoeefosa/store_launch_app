class Failure {
  final String message;
  final dynamic originalError;

  const Failure(this.message, {this.originalError});

  @override
  String toString() => message;
}
