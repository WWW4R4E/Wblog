---  
date: "2026-04-10"  
category: "技术"  
read_time: "10分钟阅读"  
title: "Git常用命令笔记"  
excerpt: "记录常用的Git命令及其用法，包括基本操作、分支管理、远程仓库等"  
tags: ["Git", "版本控制", "笔记"]  
---  

# Git常用命令笔记

Git 是一个分布式版本控制系统，用于跟踪文件变化并协作开发。虽然 Git 功能强大，但也带来了一定的复杂性。本文将记录我在日常开发中常用的 Git 命令，重点介绍那些需要详细说明的命令。

## 常用命令速览

### 基础命令（无需详细介绍）

- `git init` - 初始化新仓库
- `git add` - 添加文件到暂存区
- `git clone` - 克隆远程仓库

### 需要详细介绍的命令

- `git pull` - 拉取远程代码
- `git merge` - 合并分支
- `git rebase` - 变基操作
- `git reset` - 重置操作
- `git checkout` - 切换分支
- `git commit` - 提交修改
- `git push` - 推送代码

## 详细命令介绍

### git pull

**功能**：从远程仓库拉取并合并代码到当前分支

**用法**：`git pull [远程仓库] [分支]`

**示例**：

```bash
# 从默认远程仓库拉取当前分支
git pull

# 从指定远程仓库拉取指定分支
git pull origin main
```

推荐使用`git fetch`和`git merge`替代`git pull`

### git fetch

**功能**：从远程仓库获取代码，但不合并

**用法**：`git fetch [远程仓库] [分支]`

**示例**：

```bash
# 从所有远程仓库获取
git fetch --all

# 从指定远程仓库获取指定分支
git fetch origin main
```

### git merge

**功能**：合并指定分支到当前分支

**用法**：`git merge <分支名>`

**示例**：

```bash
# 合并feature分支到当前分支
git merge feature
```

### git rebase

**功能**：将当前分支的提交重新应用到另一个分支上

**用法**：`git rebase <基准分支>`

**示例**：

```bash
# 将当前分支的提交重新应用到main分支上
git rebase main
```

**注意**：不要在公共分支上使用rebase，否则可能会导致代码历史混乱。

### git reset

**功能**：重置当前分支的HEAD指针，可用于撤销提交

**用法**：`git reset [选项] <提交>`

**常用选项**：

- `--soft`：保留修改，只重置HEAD
- `--mixed`：重置HEAD和暂存区，保留工作区修改（默认）
- `--hard`：重置HEAD、暂存区和工作区，丢弃所有修改

**示例**：

```bash
# 撤销上一次提交，但保留修改
git reset --soft HEAD~1

# 撤销上一次提交，重置暂存区
git reset HEAD~1

# 彻底撤销上一次提交，丢弃所有修改
git reset --hard HEAD~1
```

### git checkout

**功能**：切换分支或恢复文件

**用法**：

- 切换分支：`git checkout <分支名>`
- 恢复文件：`git checkout <提交> <文件路径>`

**示例**：

```bash
# 切换到main分支
git checkout main

# 从HEAD恢复文件
git checkout HEAD -- README.md
```

### git commit

**功能**：提交暂存区的修改

**用法**：`git commit -m "提交信息"`

**常用选项**：

- `-m`：指定提交信息
- `-a`：自动添加所有已跟踪文件的修改
- `--amend`：修改上一次提交

**示例**：

```bash
# 提交暂存区修改
git commit -m "添加README文件"

# 自动添加所有修改并提交
git commit -a -m "更新代码"

# 修改上一次提交
git commit --amend -m "修正提交信息"
```

### git push

**功能**：将本地提交推送到远程仓库

**用法**：`git push [远程仓库] [分支]`

**常用选项**：

- `-f`：强制推送
- `--tags`：推送标签

**示例**：

```bash
# 推送到默认远程仓库的当前分支
git push

# 推送到指定远程仓库的指定分支
git push origin main

# 强制推送
git push -f origin main
```

### git status

**功能**：查看当前仓库状态，显示已修改和未跟踪的文件

**用法**：`git status`

### git log

**功能**：查看提交历史

**用法**：`git log [选项]`

**常用选项**：

- `-p`：显示每次提交的具体修改
- `--oneline`：以简洁格式显示
- `--graph`：显示分支合并图

**示例**：

```bash
# 查看简洁的提交历史
git log --oneline

# 查看带分支图的提交历史
git log --oneline --graph
```

### git branch

**功能**：管理分支

**用法**：

- 查看分支：`git branch`
- 创建分支：`git branch <分支名>`
- 删除分支：`git branch -d <分支名>`

**示例**：

```bash
# 查看所有分支
git branch -a

# 创建新分支
git branch feature

# 删除分支
git branch -d feature
```

### git stash

**功能**：暂存当前工作区的修改，可用于临时切换分支

**用法**：

- 暂存：`git stash`
- 查看暂存：`git stash list`
- 恢复暂存：`git stash pop`

**示例**：

```bash
# 暂存当前修改
git stash

# 查看暂存列表
git stash list

# 恢复最新的暂存
git stash pop
```

### git config

**功能**：配置Git设置

**用法**：`git config [选项] <键> <值>`

**常用配置**：

- 用户名：`git config --global user.name "Your Name"`
- 邮箱：`git config --global user.email "your.email@example.com"`
- 默认编辑器：`git config --global core.editor "vim"`

**示例**：

```bash
# 设置全局用户名
git config --global user.name "John Doe"

# 设置全局邮箱
git config --global user.email "john.doe@example.com"
```

### git remote

**功能**：管理远程仓库

**用法**：

- 查看远程仓库：`git remote -v`
- 添加远程仓库：`git remote add <名称> <URL>`
- 删除远程仓库：`git remote remove <名称>`

**示例**：

```bash
# 查看远程仓库
git remote -v

# 添加远程仓库
git remote add origin https://github.com/user/repo.git

# 删除远程仓库
git remote remove origin
```

## 本人常用的命令组合

### 撤回上一次提交并且保留修改，然后重新提交，并且覆盖远程仓库的提交记录

```bash
git reset --soft HEAD~1
git add .
git commit -m "提交信息"
git push --force
```

### 创建新分支，删除其中几次提交记录并保留修改，最终合并到主分支

```bash
git branch feature
git reset --soft HEAD~3
git add .
git commit -m "提交信息"
git push --force
git merge feature
```

### A设备提交了部分半成品代码但完整提交信息, B设备需要在该提交上附加完整代码
B设备提交部分半成品代码
```bash
git pull --rebase
git add .
git commit --amend --no-edit
git push --force
```
A设备获取云端覆盖本地提交记录
``` bash
git fetch origin
git reset --hard origin/main
```

