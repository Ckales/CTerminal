import 'dart:math' as math;
import 'dart:ui';

/// 分屏树：叶子是窗格，分支是横 / 竖排列的若干子节点和它们的比例
sealed class PaneNode<T> {
  SplitNode<T>? parent;
}

class LeafNode<T> extends PaneNode<T> {
  LeafNode(this.pane);
  final T pane;
}

class SplitNode<T> extends PaneNode<T> {
  SplitNode({required this.vertical, required List<PaneNode<T>> children, List<double>? ratios})
      : children = children,
        // 必须可增长：拆分 / 关闭窗格时要增删比例
        ratios = List.of(ratios ?? List.filled(children.length, 1 / children.length)) {
    for (final child in children) {
      child.parent = this;
    }
  }

  /// true = 上下排列
  bool vertical;
  final List<PaneNode<T>> children;
  final List<double> ratios;
}

enum SplitSide { left, right, top, bottom }

class PaneTree<T> {
  PaneTree(T pane) : root = LeafNode(pane);

  PaneNode<T> root;

  List<T> get panes {
    final result = <T>[];
    void walk(PaneNode<T> node) {
      switch (node) {
        case LeafNode<T>():
          result.add(node.pane);
        case SplitNode<T>():
          for (final child in node.children) {
            walk(child);
          }
      }
    }

    walk(root);
    return result;
  }

  LeafNode<T>? leafOf(T pane) {
    LeafNode<T>? found;
    void walk(PaneNode<T> node) {
      switch (node) {
        case LeafNode<T>():
          if (identical(node.pane, pane)) found = node;
        case SplitNode<T>():
          for (final child in node.children) {
            walk(child);
          }
      }
    }

    walk(root);
    return found;
  }

  /// 在 target 旁边插入 pane。同方向时并入父分支（平均分配），不同方向时新建分支
  void split(T target, T pane, SplitSide side) {
    final leaf = leafOf(target);
    if (leaf == null) return;
    final vertical = side == SplitSide.top || side == SplitSide.bottom;
    final after = side == SplitSide.right || side == SplitSide.bottom;
    final newLeaf = LeafNode(pane);
    final parent = leaf.parent;
    if (parent != null && parent.vertical == vertical) {
      final index = parent.children.indexOf(leaf) + (after ? 1 : 0);
      parent.children.insert(index, newLeaf);
      newLeaf.parent = parent;
      parent.ratios
        ..clear()
        ..addAll(List.filled(parent.children.length, 1 / parent.children.length));
      return;
    }
    final branch = SplitNode<T>(vertical: vertical, children: after ? [leaf, newLeaf] : [newLeaf, leaf]);
    if (parent == null) {
      root = branch;
      branch.parent = null;
    } else {
      final index = parent.children.indexOf(leaf);
      parent.children[index] = branch;
      branch.parent = parent;
    }
  }

  /// 移除窗格，返回树是否已空。只剩一个子节点的分支会被折叠
  bool remove(T pane) {
    final leaf = leafOf(pane);
    if (leaf == null) return false;
    final parent = leaf.parent;
    if (parent == null) return true;
    final index = parent.children.indexOf(leaf);
    parent.children.removeAt(index);
    final removedRatio = parent.ratios.removeAt(index);
    final remaining = 1 - removedRatio;
    for (var i = 0; i < parent.ratios.length; i++) {
      parent.ratios[i] = remaining > 0 ? parent.ratios[i] / remaining : 1 / parent.ratios.length;
    }
    if (parent.children.length == 1) {
      final only = parent.children.single;
      final grandparent = parent.parent;
      if (grandparent == null) {
        root = only;
        only.parent = null;
      } else {
        grandparent.children[grandparent.children.indexOf(parent)] = only;
        only.parent = grandparent;
      }
    }
    return false;
  }

  /// 各窗格在 [0,1]x[0,1] 中的位置，用于方向导航
  Map<T, Rect> layout() {
    final result = <T, Rect>{};
    void walk(PaneNode<T> node, Rect rect) {
      switch (node) {
        case LeafNode<T>():
          result[node.pane] = rect;
        case SplitNode<T>():
          var offset = 0.0;
          for (var i = 0; i < node.children.length; i++) {
            final ratio = node.ratios[i];
            final child = node.vertical
                ? Rect.fromLTWH(rect.left, rect.top + rect.height * offset, rect.width, rect.height * ratio)
                : Rect.fromLTWH(rect.left + rect.width * offset, rect.top, rect.width * ratio, rect.height);
            walk(node.children[i], child);
            offset += ratio;
          }
      }
    }

    walk(root, const Rect.fromLTWH(0, 0, 1, 1));
    return result;
  }

  /// 按方向找相邻窗格：该方向上重叠最多、距离最近的那个
  T? neighbor(T from, SplitSide direction) {
    final rects = layout();
    final origin = rects[from];
    if (origin == null) return null;
    T? best;
    var bestScore = double.infinity;
    const epsilon = 1e-6;
    rects.forEach((pane, rect) {
      if (identical(pane, from)) return;
      double distance;
      double overlap;
      switch (direction) {
        case SplitSide.left:
          if (rect.right > origin.left + epsilon) return;
          distance = origin.left - rect.right;
          overlap = math.min(rect.bottom, origin.bottom) - math.max(rect.top, origin.top);
        case SplitSide.right:
          if (rect.left < origin.right - epsilon) return;
          distance = rect.left - origin.right;
          overlap = math.min(rect.bottom, origin.bottom) - math.max(rect.top, origin.top);
        case SplitSide.top:
          if (rect.bottom > origin.top + epsilon) return;
          distance = origin.top - rect.bottom;
          overlap = math.min(rect.right, origin.right) - math.max(rect.left, origin.left);
        case SplitSide.bottom:
          if (rect.top < origin.bottom - epsilon) return;
          distance = rect.top - origin.bottom;
          overlap = math.min(rect.right, origin.right) - math.max(rect.left, origin.left);
      }
      if (overlap <= epsilon) return;
      final score = distance * 10 - overlap;
      if (score < bestScore) {
        bestScore = score;
        best = pane;
      }
    });
    return best;
  }

  /// 调整窗格在最近的某方向分支里的比例
  void resize(T pane, {required bool vertical, required double delta}) {
    PaneNode<T>? node = leafOf(pane);
    while (node != null) {
      final parent = node.parent;
      if (parent == null) return;
      if (parent.vertical == vertical) {
        final index = parent.children.indexOf(node);
        final neighborIndex = index + 1 < parent.children.length ? index + 1 : index - 1;
        if (neighborIndex < 0) return;
        final grow = math.min(delta, parent.ratios[neighborIndex] - 0.05);
        final shrink = math.max(grow, -(parent.ratios[index] - 0.05));
        parent.ratios[index] += shrink;
        parent.ratios[neighborIndex] -= shrink;
        return;
      }
      node = parent;
    }
  }
}
