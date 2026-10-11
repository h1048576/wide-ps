package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"wesure.cn/misc/timeutil"
	"wesure.cn/msf/errors"
)

const (
	configName  = "config.toml"
	catalogName = "models-local.json"
	backupName  = "backup-local-models"
)

// 先写模型目录，再切换 config.toml，避免配置先指向尚未生成的模型。
var managedNames = []string{catalogName, configName}

type storage struct {
	directory string
}

type fileState struct {
	exists bool
	data   []byte
	mode   os.FileMode
}

// 与 PowerShell 脚本的 version=1 清单兼容，指针区分缺失字段和 false。
type manifest struct {
	Version int              `json:"version"`
	Files   map[string]*bool `json:"files"`
}

func newStorage(requested string) (*storage, error) {
	if requested == "" {
		requested = os.Getenv("CODEX_HOME")
	}
	if requested == "" {
		userDirectory, err := os.UserHomeDir()
		if err != nil {
			return nil, failure("无法获取用户目录：%+v", err)
		}
		requested = filepath.Join(userDirectory, ".codex")
	}
	directory, err := filepath.Abs(requested)
	if err != nil {
		return nil, failure("无法解析 Codex 配置目录：%+v", err)
	}
	return &storage{directory: directory}, nil
}

func (store *storage) initialPath() string {
	return filepath.Join(store.directory, backupName, "initial")
}

func (store *storage) lock() (func(), error) {
	if err := os.MkdirAll(store.directory, 0700); err != nil {
		return nil, failure("创建 Codex 配置目录失败：%+v", err)
	}
	path := filepath.Join(store.directory, ".codex-switch.lock")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if os.IsExist(err) {
		return nil, failure("配置目录已被锁定：%s。请等待其他 CLI 操作完成；若上次进程异常退出，确认没有运行中的操作后删除此锁文件。", path)
	}
	if err != nil {
		return nil, failure("获取配置目录锁失败：%+v", err)
	}
	_, writeErr := fmt.Fprintf(file, "pid=%d\n", os.Getpid())
	closeErr := file.Close()
	if writeErr != nil || closeErr != nil {
		os.Remove(path)
		return nil, errors.New("写入配置目录锁失败。")
	}
	return func() {
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			fmt.Fprintf(os.Stderr, "释放配置目录锁失败：%+v\n", err)
		}
	}, nil
}

func readFileState(path string) (fileState, error) {
	info, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return fileState{}, nil
	}
	if err != nil {
		return fileState{}, failure("读取文件属性 %s 失败：%+v", path, err)
	}
	if !info.Mode().IsRegular() {
		return fileState{}, failure("%s 必须是普通文件，不能是目录或符号链接。", path)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return fileState{}, failure("读取文件 %s 失败：%+v", path, err)
	}
	return fileState{exists: true, data: data, mode: info.Mode().Perm()}, nil
}

func (store *storage) readCurrent() (map[string]fileState, error) {
	states := make(map[string]fileState)
	for _, name := range managedNames {
		state, err := readFileState(filepath.Join(store.directory, name))
		if err != nil {
			return nil, err
		}
		states[name] = state
	}
	return states, nil
}

func readSnapshot(directory string) (map[string]fileState, error) {
	state, err := readFileState(filepath.Join(directory, "manifest.json"))
	if err != nil {
		return nil, err
	}
	if !state.exists {
		return nil, failure("备份清单不存在：%s", filepath.Join(directory, "manifest.json"))
	}
	var metadata manifest
	if err := json.Unmarshal(trimBOM(state.data), &metadata); err != nil || metadata.Version != 1 {
		return nil, errors.New("备份清单无效或版本不受支持。")
	}
	states := make(map[string]fileState)
	for _, name := range managedNames {
		exists := metadata.Files[name]
		if exists == nil {
			return nil, failure("备份清单中的 %s 标记缺失或无效。", name)
		}
		states[name] = fileState{}
		if *exists {
			state, err := readFileState(filepath.Join(directory, name))
			if err != nil {
				return nil, err
			}
			if !state.exists {
				return nil, failure("备份文件缺失：%s", name)
			}
			states[name] = state
		}
	}
	return states, nil
}

func (store *storage) saveSnapshot(states map[string]fileState, initial bool) (string, error) {
	parent := filepath.Join(store.directory, backupName)
	if err := os.MkdirAll(parent, 0700); err != nil {
		return "", failure("创建备份目录失败：%+v", err)
	}
	temporary, err := os.MkdirTemp(parent, ".pending-")
	if err != nil {
		return "", failure("创建临时备份失败：%+v", err)
	}
	defer os.RemoveAll(temporary)
	metadata := manifest{Version: 1, Files: make(map[string]*bool)}
	for _, name := range managedNames {
		state := states[name]
		exists := state.exists
		metadata.Files[name] = &exists
		if exists {
			if err := atomicWrite(filepath.Join(temporary, name), state.data, 0600); err != nil {
				return "", failure("写入备份 %s 失败：%+v", name, err)
			}
		}
	}
	data, err := json.MarshalIndent(metadata, "", "  ")
	if err != nil {
		return "", err
	}
	if err := atomicWrite(filepath.Join(temporary, "manifest.json"), append(data, '\n'), 0600); err != nil {
		return "", failure("写入备份清单失败：%+v", err)
	}
	name := time.Now().Format(timeutil.DateTimeFormat) + "-" + filepath.Base(temporary)[len(".pending-"):]
	if initial {
		name = "initial"
	}
	destination := filepath.Join(parent, name)
	if _, err := os.Lstat(destination); err == nil {
		return "", failure("备份目录已存在：%s", destination)
	} else if !os.IsNotExist(err) {
		return "", err
	}
	if err := os.Rename(temporary, destination); err != nil {
		return "", failure("保存备份失败：%+v", err)
	}
	return destination, nil
}

func (store *storage) commit(current, target map[string]fileState, keepInitial bool) (string, error) {
	if keepInitial {
		_, err := os.Lstat(store.initialPath())
		if os.IsNotExist(err) {
			if _, err := store.saveSnapshot(current, true); err != nil {
				return "", err
			}
		} else if err != nil {
			return "", err
		} else if _, err := readSnapshot(store.initialPath()); err != nil {
			return "", failure("首次备份不完整，已停止操作以保留原配置：%+v", err)
		}
	}
	backup, err := store.saveSnapshot(current, false)
	if err != nil {
		return "", err
	}
	if err := store.apply(target, current); err != nil {
		if rollbackErr := store.apply(current, current); rollbackErr != nil {
			return "", failure("修改失败：%+v\n自动回滚失败：%+v\n请从此备份恢复：%s", err, rollbackErr, backup)
		}
		return "", failure("修改失败，已回滚到本次操作前：%+v\n本次备份：%s", err, backup)
	}
	return backup, nil
}

func (store *storage) apply(states, previous map[string]fileState) error {
	for _, name := range managedNames {
		path := filepath.Join(store.directory, name)
		state := states[name]
		actual, err := readFileState(path)
		if err != nil {
			return err
		}
		// 回滚时跳过仍是原始内容的文件，避免只读文件将已完成的回滚误报为失败。
		if actual.exists == state.exists && bytes.Equal(actual.data, state.data) {
			continue
		}
		if !state.exists {
			if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
				return failure("恢复文件不存在状态 %s 失败：%+v", name, err)
			}
			continue
		}
		mode := previous[name].mode
		if mode == 0 {
			mode = 0600
		}
		if err := atomicWrite(path, state.data, mode); err != nil {
			return failure("写入 %s 失败：%+v", name, err)
		}
	}
	return nil
}

func atomicWrite(path string, data []byte, mode os.FileMode) error {
	if mode&0200 == 0 {
		return errors.New("目标文件为只读，无法写入。")
	}
	file, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+"-*.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	defer file.Close()
	if _, err := file.Write(data); err != nil {
		return err
	}
	if err := file.Chmod(mode); err != nil {
		return err
	}
	if err := file.Sync(); err != nil {
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	return replaceFile(file.Name(), path)
}
