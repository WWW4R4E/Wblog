---
date: "2026-04-10"  
category: "技术"  
read_time: "8分钟阅读"  
title: "LINQ 核心概念解析"  
excerpt: "深入解析LINQ的核心概念，包括Enumerable与Queryable的区别、委托与表达式树的差异，以及LINQ的语法演变。"  
tags: ["LINQ", "CSharp", "笔记"]  
---

## LINQ

LINQ的核心由两大静态类组成Enumerable vs Queryable，其中的where等就是静态类中包含的扩展方法，类似于正常调用任何类的扩展方法的方式。  
LINQ方法语法又称Fluent语法（连贯语法）
### Enumerable vs Queryable

这两个静态类结构几乎一样，但适用场景和执行方式完全不同。

|    特性     |             Enumerable             |              Queryable               |
| :---------: | :--------------------------------: | :----------------------------------: |
|  目标接口   |          `IEnumerable<T>`          |           `IQueryable<T>`            |
|   数据源    |            内存中的集合            |        远程数据源（数据库等）        |
|  代表类型   | `List<T>`, `Dictionary<K,V>`, 数组 |    Entity Framework 的 `DbSet<T>`    |
| Lambda 参数 |        `Func<T, bool>` 委托        | `Expression<Func<T, bool>>` 表达式树 |
|  执行方式   |         直接执行，本地计算         |         翻译成 SQL，远程执行         |
|  延迟执行   |         支持（迭代时执行）         |       支持（翻译 + 远程执行）        |

### 核心差异：委托 vs 表达式树

```csharp
// Enumerable.Where 接受委托
public static IEnumerable<T> Where<T>(
    this IEnumerable<T> source, 
    Func<T, bool> predicate)  // 委托
```

```csharp
// Queryable.Where 接受表达式树
public static IQueryable<T> Where<T>(
    this IQueryable<T> source, 
    Expression<Func<T, bool>> predicate)  // 表达式树
```

**为什么不同？**

- `Enumerable`：你传给它的是编译好的代码（委托），它在内存里遍历集合、逐条调用
- `Queryable`：你传给它的是代码结构（表达式树），它把这个结构翻译成 SQL 语句，发给数据库执行

### 实际例子

```csharp
// 内存集合 → 使用 Enumerable
List<Student> students = GetStudents();
var teens = students.Where(s => s.Age > 12);  // Enumerable.Where
// 编译为：遍历内存中的每个学生，判断条件

// Entity Framework → 使用 Queryable
DbContext db = new DbContext();
var teens = db.Students.Where(s => s.Age > 12);  // Queryable.Where
// 编译为：SELECT * FROM Students WHERE Age > 12
```


## LINQ 语法演变

### delegate
先通过委托传递条件列如
```csharp
delegate(Student s) 