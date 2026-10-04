import 'package:flutter/material.dart';

import '../../../widgets/append_pagination_footer.dart';

class Hanime1Pagination extends StatelessWidget {
  const Hanime1Pagination({
    super.key,
    required this.currentPage,
    required this.totalPages,
    required this.onPageChanged,
    this.isLoading = false,
    this.onNext,
    this.hasNext,
    this.error,
  });
  final int currentPage;
  final int totalPages;
  final ValueChanged<int> onPageChanged;
  final bool isLoading;
  final VoidCallback? onNext;
  final bool? hasNext;
  final String? error;
  @override
  Widget build(BuildContext context) => AppendPaginationFooter(
    page: currentPage,
    hasMore: hasNext ?? currentPage < totalPages,
    loading: isLoading,
    error: error,
    onJump: onPageChanged,
    onNext: onNext ?? () => onPageChanged(currentPage + 1),
  );
}
