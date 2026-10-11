package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"text/tabwriter"

	"golang.org/x/net/context"
	"wesure.cn/msf/errors"
)

const usage = `codex-switch：管理 Codex 本地模型

用法：codex-switch <命令> [参数]

命令：
  list      列出 JSON 中的模型、可选档位和默认档位
  install   同步全部模型，默认选用 JSON 中第一个模型
  switch    切换默认模型，例如 switch glm-5.3-flashx
  menu      交互式选择模型或恢复原配置
  status    查看当前配置文件及模型设置
  restore   恢复首次安装前的配置，不依赖模型 JSON
  help      显示帮助；<命令> --help 查看命令参数

示例：
  codex-switch list
  codex-switch install --skip-connection-check
  codex-switch switch glm-5.3-flashx
  codex-switch menu --config D:\codex\codex-switch\codex-local-models.json
  codex-switch status --codex-home D:\codex-profile
  codex-switch restore

模型支持完整 ID、唯一显示名称或 ID 最后一段；默认思考档位取 effect 最后一项。
配置依次查找当前目录、当前目录的父目录、可执行文件目录及其两级父目录。
也可用 --config 或 CODEX_SWITCH_CONFIG 指定配置文件。
API 密钥优先使用 --api-key，其次 CODEX_SWITCH_API_KEY，最后 JSON 的 apiKey。
目标目录优先使用 --codex-home，其次 CODEX_HOME，最后用户目录下的 .codex。
源代码使用 GOPATH 依赖；在 cli 目录执行 go build -o bin/codex-switch.exe . 编译。
`

type application struct {
	input   io.Reader
	output  io.Writer
	secrets []string
}

type options struct {
	configFile string
	codexHome  string
	model      string
	baseURL    string
	apiKey     string
	skipCheck  bool
	jsonOutput bool
	provided   map[string]bool
}

func main() {
	app := &application{input: os.Stdin, output: os.Stdout}
	ctx, cancel := context.WithCancel(context.Background())
	interrupts := make(chan os.Signal, 1)
	signal.Notify(interrupts, os.Interrupt)
	go func() {
		select {
		case <-interrupts:
			cancel()
		case <-ctx.Done():
		}
	}()
	err := app.run(ctx, os.Args[1:])
	signal.Stop(interrupts)
	cancel()
	if err != nil {
		fmt.Fprintf(os.Stderr, "错误：%+v\n", app.safeMessage(err))
		os.Exit(1)
	}
}

func failure(format string, args ...interface{}) error {
	return errors.New(fmt.Sprintf(format, args...))
}

func (app *application) safeMessage(err error) string {
	message := fmt.Sprintf("%+v", err)
	for _, secret := range app.secrets {
		if secret != "" {
			message = strings.ReplaceAll(message, secret, "[已隐藏密钥]")
		}
	}
	return message
}

func (app *application) run(ctx context.Context, args []string) error {
	if len(args) == 0 || args[0] == "help" || args[0] == "--help" || args[0] == "-h" {
		fmt.Fprint(app.output, usage)
		return nil
	}
	command := args[0]
	switch command {
	case "list", "install", "switch", "menu", "status", "restore":
	default:
		return failure("未知命令 %q，请运行 codex-switch help。", command)
	}
	opt, positional, err := app.parseOptions(command, args[1:])
	if err == flag.ErrHelp {
		return nil
	}
	if err != nil {
		return err
	}
	if len(positional) > 0 {
		if command != "switch" || len(positional) != 1 || opt.provided["model"] {
			return errors.New("位置参数仅用于 switch <模型>，不能同时指定 --model。")
		}
		opt.model = positional[0]
	}
	if command == "switch" && strings.TrimSpace(opt.model) == "" {
		return errors.New("请指定要切换的模型，例如 codex-switch switch glm-5.3-flashx。")
	}
	if command == "status" || command == "restore" {
		store, err := newStorage(opt.codexHome)
		if err != nil {
			return err
		}
		if command == "status" {
			return app.showStatus(store)
		}
		return app.restore(store)
	}
	configPath, err := findSettings(opt.configFile)
	if err != nil {
		return err
	}
	settings, err := readSettings(configPath)
	if err != nil {
		return err
	}
	app.secrets = append(app.secrets, settings.GetAPIKey())
	if command == "list" {
		return app.listModels(settings, opt.jsonOutput)
	}
	if opt.provided["base-url"] {
		settings.BaseURL = opt.baseURL
	}
	if opt.provided["api-key"] || opt.apiKey != "" {
		settings.APIKey = opt.apiKey
	}
	store, err := newStorage(opt.codexHome)
	if err != nil {
		return err
	}
	var selected *model
	if command == "menu" {
		choice, restore, err := app.selectMenu(settings)
		if err != nil {
			return err
		}
		if restore {
			return app.restore(store)
		}
		if choice == nil {
			return nil
		}
		selected = choice
	} else {
		selected, err = settings.selectModel(opt.model)
		if err != nil {
			return err
		}
	}
	return app.install(ctx, store, settings, selected, configPath, opt.skipCheck)
}

func (app *application) parseOptions(command string, args []string) (*options, []string, error) {
	opt := &options{provided: make(map[string]bool)}
	flags := flag.NewFlagSet(command, flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	if command != "status" && command != "restore" {
		flags.StringVar(&opt.configFile, "config", os.Getenv("CODEX_SWITCH_CONFIG"), "模型 JSON 配置文件路径")
	}
	if command != "list" {
		flags.StringVar(&opt.codexHome, "codex-home", "", "Codex 配置目录，默认使用 CODEX_HOME 或用户目录下的 .codex")
	}
	if command == "install" || command == "switch" || command == "menu" {
		if command != "menu" {
			flags.StringVar(&opt.model, "model", "", "完整模型 ID、唯一显示名称或 ID 最后一段")
		}
		flags.StringVar(&opt.baseURL, "base-url", "", "覆盖 JSON 中的本机网关地址，必须以 /v1 结尾")
		flags.StringVar(&opt.apiKey, "api-key", "", "覆盖网关 API 密钥，也可设置 CODEX_SWITCH_API_KEY")
		flags.BoolVar(&opt.skipCheck, "skip-connection-check", false, "跳过网关模型列表和 Responses 流式接口检查")
	}
	if command == "list" {
		flags.BoolVar(&opt.jsonOutput, "json", false, "以 JSON 输出模型列表，不包含连接密钥")
	}
	flags.Usage = func() {
		fmt.Fprintf(app.output, "用法：codex-switch %s [参数]\n", command)
		if command == "switch" {
			fmt.Fprintln(app.output, "也可使用：codex-switch switch <模型> [参数]")
		}
		flags.SetOutput(app.output)
		flags.PrintDefaults()
		flags.SetOutput(io.Discard)
	}
	// 允许 switch <模型> --config <路径>，不受标准 flag 在位置参数处停止解析的限制。
	var flagArgs, positional []string
	app.secrets = append(app.secrets, os.Getenv("CODEX_SWITCH_API_KEY"))
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if arg == "--" {
			positional = append(positional, args[i+1:]...)
			break
		}
		if !strings.HasPrefix(arg, "-") || arg == "-" {
			positional = append(positional, arg)
			continue
		}
		name, value, assigned := strings.Cut(strings.TrimLeft(arg, "-"), "=")
		if name == "help" || name == "h" {
			flags.Usage()
			return nil, nil, flag.ErrHelp
		}
		entry := flags.Lookup(name)
		if entry == nil {
			return nil, nil, failure("未知参数 --%s，请运行 codex-switch %s --help。", name, command)
		}
		flagArgs = append(flagArgs, arg)
		boolFlag, isBool := entry.Value.(interface{ IsBoolFlag() bool })
		if !assigned && !(isBool && boolFlag.IsBoolFlag()) {
			if i+1 >= len(args) {
				return nil, nil, failure("参数 --%s 缺少值。", name)
			}
			i++
			value = args[i]
			flagArgs = append(flagArgs, value)
		}
		if name == "api-key" {
			app.secrets = append(app.secrets, value)
		}
	}
	if err := flags.Parse(flagArgs); err != nil {
		return nil, nil, failure("参数无效：%+v", err)
	}
	flags.Visit(func(entry *flag.Flag) { opt.provided[entry.Name] = true })
	if !opt.provided["api-key"] {
		opt.apiKey = os.Getenv("CODEX_SWITCH_API_KEY")
	}
	return opt, positional, nil
}

func (app *application) listModels(settings *modelSettings, asJSON bool) error {
	if asJSON {
		encoder := json.NewEncoder(app.output)
		encoder.SetIndent("", "  ")
		return encoder.Encode(settings.GetModels())
	}
	w := tabwriter.NewWriter(app.output, 0, 4, 2, ' ', 0)
	fmt.Fprintln(w, "模型 ID\t显示名称\t可选思考档位\t默认档位")
	for _, entry := range settings.GetModels() {
		fmt.Fprintf(w, "%s\t%s\t%s\t%s\n", entry.GetModel(), entry.GetDisplayName(), strings.Join(entry.GetEffect(), " / "), entry.GetDefaultEffect())
	}
	return w.Flush()
}

func (app *application) selectMenu(settings *modelSettings) (*model, bool, error) {
	models := settings.GetModels()
	for i, entry := range models {
		number := i + 1
		if number >= 9 {
			number++
		}
		fmt.Fprintf(app.output, "%d. %s [%s]，档位：%s（默认 %s）\n", number, entry.GetDisplayName(), entry.GetModel(), strings.Join(entry.GetEffect(), " / "), entry.GetDefaultEffect())
	}
	fmt.Fprintln(app.output, "9. 恢复首次安装前的配置\n0. 退出")
	fmt.Fprint(app.output, "请选择，直接回车使用第一个模型：")
	line, err := bufio.NewReader(app.input).ReadString('\n')
	if err != nil && !(err == io.EOF && len(line) > 0) {
		if err == io.EOF {
			return nil, false, errors.New("未读取到菜单输入，已退出；自动化调用请使用 install 或 switch。")
		}
		return nil, false, failure("读取菜单输入失败：%+v", err)
	}
	choice := strings.TrimSpace(line)
	switch choice {
	case "0":
		return nil, false, nil
	case "9":
		return nil, true, nil
	case "":
		return models[0], false, nil
	}
	number, err := strconv.Atoi(choice)
	if err != nil {
		return nil, false, errors.New("无效的菜单选项。")
	}
	if number > 9 {
		number--
	}
	if number < 1 || number > len(models) {
		return nil, false, errors.New("无效的菜单选项。")
	}
	return models[number-1], false, nil
}

func (app *application) install(ctx context.Context, store *storage, settings *modelSettings, selected *model, source string, skipCheck bool) error {
	if err := settings.validateConnection(); err != nil {
		return err
	}
	if !skipCheck {
		fmt.Fprintln(app.output, "检查模型列表和 Responses 流式接口……")
		if err := checkEndpoint(ctx, settings, selected); err != nil {
			return failure("连接检查失败：%+v\n原配置未修改；仅准备配置可使用 --skip-connection-check。", err)
		}
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	unlock, err := store.lock()
	if err != nil {
		return err
	}
	defer unlock()
	current, err := store.readCurrent()
	if err != nil {
		return err
	}
	config, err := makeConfig(current[configName].data, store, settings, selected)
	if err != nil {
		return err
	}
	catalog, err := makeCatalog(settings)
	if err != nil {
		return err
	}
	target := map[string]fileState{
		configName:  {exists: true, data: config},
		catalogName: {exists: true, data: catalog},
	}
	backup, err := store.commit(current, target, true)
	if err != nil {
		return err
	}
	fmt.Fprintf(app.output, "已同步 %d 个模型，默认使用 %s [%s]\n", len(settings.GetModels()), selected.GetDisplayName(), selected.GetModel())
	fmt.Fprintf(app.output, "思考等级：%s；可选档位：%s；上下文：1M\n", selected.GetDefaultEffect(), strings.Join(selected.GetEffect(), " / "))
	fmt.Fprintf(app.output, "模型来源：%s\n配置文件：%s\n模型目录：%s\n", source, filepath.Join(store.directory, configName), filepath.Join(store.directory, catalogName))
	app.printCompletion(backup)
	if skipCheck {
		fmt.Fprintln(app.output, "已跳过连接检查，实际使用需要本地网关支持 Responses API。")
	}
	return nil
}

func (app *application) restore(store *storage) error {
	unlock, err := store.lock()
	if err != nil {
		return err
	}
	defer unlock()
	target, err := readSnapshot(store.initialPath())
	if err != nil {
		return failure("无法读取首次安装前的备份：%+v", err)
	}
	current, err := store.readCurrent()
	if err != nil {
		return err
	}
	backup, err := store.commit(current, target, false)
	if err != nil {
		return err
	}
	fmt.Fprintln(app.output, "已恢复首次安装前的配置，包括原上下文及压缩设置。")
	app.printCompletion(backup)
	return nil
}

func (app *application) printCompletion(backup string) {
	fmt.Fprintf(app.output, "本次操作前的备份：%s\n", backup)
	fmt.Fprintln(app.output, "请完全退出并重新打开 Codex 桌面端 / IDE 插件，CLI 请重新启动。已有对话可能保留原模型及档位。")
}
