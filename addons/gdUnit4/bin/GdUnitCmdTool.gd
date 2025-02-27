#!/usr/bin/env -S godot -s
extends SceneTree

const GdUnitTools := preload("res://addons/gdUnit4/src/core/GdUnitTools.gd")


#warning-ignore-all:return_value_discarded
class CLIRunner:
	extends Node

	enum {
		READY,
		INIT,
		RUN,
		STOP,
		EXIT
	}

	const DEFAULT_REPORT_COUNT = 20
	const RETURN_SUCCESS = 0
	const RETURN_ERROR = 100
	const RETURN_ERROR_HEADLESS_NOT_SUPPORTED = 103
	const RETURN_ERROR_GODOT_VERSION_NOT_SUPPORTED = 104
	const RETURN_WARNING = 101

	var _state = READY
	var _test_suites_to_process: Array
	var _executor
	var _cs_executor
	var _report: GdUnitHtmlReport
	var _report_dir: String
	var _report_max: int = DEFAULT_REPORT_COUNT
	var _headless_mode_ignore := false
	var _runner_config := GdUnitRunnerConfig.new()
	var _console := CmdConsole.new()
	var _cmd_options := CmdOptions.new([
			CmdOption.new(
				"-a, --add",
				"-a <directory|path of testsuite>",
				"Adds the given test suite or directory to the execution pipeline.",
				TYPE_STRING
			),
			CmdOption.new(
				"-i, --ignore",
				"-i <testsuite_name|testsuite_name:test-name>",
				"Adds the given test suite or test case to the ignore list.",
				TYPE_STRING
			),
			CmdOption.new(
					"-c, --continue",
					"",
					"""By default GdUnit will abort checked first test failure to be fail fast,
					instead of stop after first failure you can use this option to run the complete test set.""".dedent()
			),
			CmdOption.new(
				"-conf, --config",
				"-conf [testconfiguration.cfg]",
				"Run all tests by given test configuration. Default is 'GdUnitRunner.cfg'",
				TYPE_STRING,
				true
			),
			CmdOption.new(
				"-help", "",
				"Shows this help message."
			),
			CmdOption.new("--help-advanced", "",
				"Shows advanced options."
			)
		],
		[
			# advanced options
			CmdOption.new(
				"-rd, --report-directory",
				"-rd <directory>",
				"Specifies the output directory in which the reports are to be written. The default is res://reports/.",
				TYPE_STRING,
				true
			),
			CmdOption.new(
				"-rc, --report-count",
				"-rc <count>",
				"Specifies how many reports are saved before they are deleted. The default is %s." % str(DEFAULT_REPORT_COUNT),
				TYPE_INT,
				true
			),
			#CmdOption.new("--list-suites", "--list-suites [directory]", "Lists all test suites located in the given directory.", TYPE_STRING),
			#CmdOption.new("--describe-suite", "--describe-suite <suite name>", "Shows the description of selected test suite.", TYPE_STRING),
			CmdOption.new(
				"--info", "",
				"Shows the GdUnit version info"
			),
			CmdOption.new(
				"--selftest", "",
				"Runs the GdUnit self test"
			),
			CmdOption.new(
				"--ignoreHeadlessMode",
				"--ignoreHeadlessMode",
				"By default, running GdUnit4 in headless mode is not allowed. You can switch off the headless mode check by set this property."
			),
		])


	func _ready():
		_state = INIT
		_report_dir = GdUnitFileAccess.current_dir() + "reports"
		_executor = load("res://addons/gdUnit4/src/core/execution/GdUnitTestSuiteExecutor.gd").new()
		# stop checked first test failure to fail fast
		_executor.fail_fast(true)
		if GdUnit4CSharpApiLoader.is_mono_supported():
			prints("GdUnit4Net version '%s' loaded." % GdUnit4CSharpApiLoader.version())
			_cs_executor = GdUnit4CSharpApiLoader.create_executor(self)
		var err := GdUnitSignals.instance().gdunit_event.connect(_on_gdunit_event)
		if err != OK:
			prints("gdUnitSignals failed")
			push_error("Error checked startup, can't connect executor for 'send_event'")
			quit(RETURN_ERROR)


	func _notification(what: int) -> void:
		if what == NOTIFICATION_PREDELETE:
			prints("Finallize .. done")


	func _process(_delta :float) -> void:
		match _state:
			INIT:
				init_gd_unit()
				_state = RUN
			RUN:
				# all test suites executed
				if _test_suites_to_process.is_empty():
					_state = STOP
				else:
					set_process(false)
					# process next test suite
					var test_suite := _test_suites_to_process.pop_front() as Node
					if _cs_executor != null and _cs_executor.IsExecutable(test_suite):
						_cs_executor.Execute(test_suite)
						await _cs_executor.ExecutionCompleted
					else:
						await _executor.execute(test_suite)
					set_process(true)
			STOP:
				_state = EXIT
				_on_gdunit_event(GdUnitStop.new())
				quit(report_exit_code(_report))


	func quit(code: int) -> void:
		_cs_executor = null
		GdUnitTools.dispose_all()
		await GdUnitMemoryObserver.gc_on_guarded_instances()
		await get_tree().physics_frame
		get_tree().quit(code)


	func set_report_dir(path: String) -> void:
		_report_dir = ProjectSettings.globalize_path(GdUnitFileAccess.make_qualified_path(path))
		_console.prints_color(
			"Set write reports to %s" % _report_dir,
			Color.DEEP_SKY_BLUE
		)


	func set_report_count(count: String) -> void:
		var report_count := count.to_int()
		if report_count < 1:
			_console.prints_error(
				"Invalid report history count '%s' set back to default %d"
				% [count, DEFAULT_REPORT_COUNT]
			)
			_report_max = DEFAULT_REPORT_COUNT
		else:
			_console.prints_color(
				"Set report history count to %s" % count,
				Color.DEEP_SKY_BLUE
			)
			_report_max = report_count


	func disable_fail_fast() -> void:
		_console.prints_color(
			"Disabled fail fast!",
			Color.DEEP_SKY_BLUE
		)
		_executor.fail_fast(false)


	func run_self_test() -> void:
		_console.prints_color(
			"Run GdUnit4 self tests.",
			Color.DEEP_SKY_BLUE
		)
		disable_fail_fast()
		_runner_config.self_test()


	func show_version() -> void:
		_console.prints_color(
			"Godot %s" % Engine.get_version_info().get("string"),
			Color.DARK_SALMON
		)
		var config := ConfigFile.new()
		config.load("addons/gdUnit4/plugin.cfg")
		_console.prints_color(
			"GdUnit4 %s" % config.get_value("plugin", "version"),
			Color.DARK_SALMON
		)
		quit(RETURN_SUCCESS)


	func check_headless_mode() -> void:
		_headless_mode_ignore = true


	func show_options(show_advanced: bool = false) -> void:
		_console.prints_color(
			"""
			Usage:
				runtest -a <directory|path of testsuite>
				runtest -a <directory> -i <path of testsuite|testsuite_name|testsuite_name:test_name>
				""".dedent(),
			Color.DARK_SALMON
		).prints_color(
			"-- Options ---------------------------------------------------------------------------------------",
			Color.DARK_SALMON
		).new_line()
		for option in _cmd_options.default_options():
			descripe_option(option)
		if show_advanced:
			_console.prints_color(
				"-- Advanced options --------------------------------------------------------------------------",
				Color.DARK_SALMON
			).new_line()
			for option in _cmd_options.advanced_options():
				descripe_option(option)


	func descripe_option(cmd_option: CmdOption) -> void:
		_console.print_color(
			"  %-40s" % str(cmd_option.commands()),
			Color.CORNFLOWER_BLUE
		)
		_console.prints_color(
			cmd_option.description(),
			Color.LIGHT_GREEN
		)
		if not cmd_option.help().is_empty():
			_console.prints_color(
				"%-4s %s" % ["", cmd_option.help()],
				Color.DARK_TURQUOISE
			)
		_console.new_line()


	func load_test_config(path := GdUnitRunnerConfig.CONFIG_FILE) -> void:
		_console.print_color(
			"Loading test configuration %s\n" % path,
			Color.CORNFLOWER_BLUE
		)
		_runner_config.load_config(path)


	func show_help() -> void:
		show_options()
		quit(RETURN_SUCCESS)


	func show_advanced_help() -> void:
		show_options(true)
		quit(RETURN_SUCCESS)


	func init_gd_unit() -> void:
		_console.prints_color(
			"""
			--------------------------------------------------------------------------------------------------
			GdUnit4 Comandline Tool
			--------------------------------------------------------------------------------------------------""".dedent(),
			Color.DARK_SALMON
		).new_line()

		var cmd_parser := CmdArgumentParser.new(_cmd_options, "GdUnitCmdTool.gd")
		var result := cmd_parser.parse(OS.get_cmdline_args())
		if result.is_error():
			show_options()
			_console.prints_error(result.error_message())
			_console.prints_error("Abnormal exit with %d" % RETURN_ERROR)
			_state = STOP
			quit(RETURN_ERROR)
			return
		if result.is_empty():
			show_help()
			return
		# build runner config by given commands
		result = (
			CmdCommandHandler.new(_cmd_options)
				.register_cb("-help", Callable(self, "show_help"))
				.register_cb("--help-advanced", Callable(self, "show_advanced_help"))
				.register_cb("-a", Callable(_runner_config, "add_test_suite"))
				.register_cbv("-a", Callable(_runner_config, "add_test_suites"))
				.register_cb("-i", Callable(_runner_config, "skip_test_suite"))
				.register_cbv("-i", Callable(_runner_config, "skip_test_suites"))
				.register_cb("-rd", set_report_dir)
				.register_cb("-rc", set_report_count)
				.register_cb("--selftest", run_self_test)
				.register_cb("-c", disable_fail_fast)
				.register_cb("-conf", load_test_config)
				.register_cb("--info", show_version)
				.register_cb("--ignoreHeadlessMode", check_headless_mode)
				.execute(result.value())
		)
		if result.is_error():
			_console.prints_error(result.error_message())
			_state = STOP
			quit(RETURN_ERROR)

		if DisplayServer.get_name() == "headless":
			if _headless_mode_ignore:
				_console.prints_warning("""
					Headless mode is ignored by option '--ignoreHeadlessMode'"

					Please note that tests that use UI interaction do not work correctly in headless mode.
					Godot 'InputEvents' are not transported by the Godot engine in headless mode and therefore
					have no effect in the test!
					""".dedent()
				).new_line()
			else:
				_console.prints_error("""
					Headless mode is not supported!

					Please note that tests that use UI interaction do not work correctly in headless mode.
					Godot 'InputEvents' are not transported by the Godot engine in headless mode and therefore
					have no effect in the test!

					You can run with '--ignoreHeadlessMode' to swtich off this check.
					""".dedent()
				).prints_error(
					"Abnormal exit with %d" % RETURN_ERROR_HEADLESS_NOT_SUPPORTED
				)
				quit(RETURN_ERROR_HEADLESS_NOT_SUPPORTED)
				return

		_test_suites_to_process = load_testsuites(_runner_config)
		if _test_suites_to_process.is_empty():
			_console.prints_warning("No test suites found, abort test run!")
			_console.prints_color("Exit code: %d" % RETURN_SUCCESS, Color.DARK_SALMON)
			_state = STOP
			quit(RETURN_SUCCESS)
		var total_test_count := _collect_test_case_count(_test_suites_to_process)
		_on_gdunit_event(GdUnitInit.new(_test_suites_to_process.size(), total_test_count))


	func load_testsuites(config: GdUnitRunnerConfig) -> Array[Node]:
		var test_suites_to_process: Array[Node] = []
		var to_execute := config.to_execute()
		# scan for the requested test suites
		var ts_scanner := GdUnitTestSuiteScanner.new()
		for as_resource_path in to_execute.keys():
			var selected_tests: PackedStringArray = to_execute.get(as_resource_path)
			var scaned_suites := ts_scanner.scan(as_resource_path)
			skip_test_case(scaned_suites, selected_tests)
			test_suites_to_process.append_array(scaned_suites)
		skip_suites(test_suites_to_process, config)
		return test_suites_to_process


	func skip_test_case(test_suites: Array, test_case_names: Array) -> void:
		if test_case_names.is_empty():
			return
		for test_suite in test_suites:
			for test_case in test_suite.get_children():
				if not test_case_names.has(test_case.get_name()):
					test_suite.remove_child(test_case)
					test_case.free()


	func skip_suites(test_suites: Array, config: GdUnitRunnerConfig) -> void:
		var skipped := config.skipped()
		for test_suite in test_suites:
			skip_suite(test_suite, skipped)


	func skip_suite(test_suite: Node, skipped: Dictionary) -> void:
		var skipped_suites := skipped.keys()
		if skipped_suites.is_empty():
			return
		var suite_name := test_suite.get_name()
		# skipp c# testsuites for now
		if test_suite.get_script() == null:
			return
		var test_suite_path: String = (
			test_suite.get_meta("ResourcePath") if test_suite.get_script() == null
			else test_suite.get_script().resource_path
		)
		for suite_to_skip in skipped_suites:
			# if suite skipped by path or name
			if (
				suite_to_skip == test_suite_path
				or (suite_to_skip.is_valid_filename() and suite_to_skip == suite_name)
			):
				var skipped_tests: Array = skipped.get(suite_to_skip)
				# if no tests skipped test the complete suite is skipped
				if skipped_tests.is_empty():
					_console.prints_warning("Skip test suite %s:%s" % suite_to_skip)
					test_suite.skip(true)
				else:
					# skip tests
					for test_to_skip in skipped_tests:
						var test_case: _TestCase = test_suite.find_child(test_to_skip, true, false)
						if test_case:
							test_case.skip(true)
							_console.prints_warning("Skip test case %s:%s" % [suite_to_skip, test_to_skip])
						else:
							_console.prints_error(
								"Can't skip test '%s' checked test suite '%s', no test with given name exists!"
								% [test_to_skip, suite_to_skip]
							)


	func _collect_test_case_count(test_suites: Array) -> int:
		var total: int = 0
		for test_suite in test_suites:
			total += (test_suite as Node).get_child_count()
		return total


	# gdlint: disable=function-name
	func PublishEvent(data: Dictionary) -> void:
		_on_gdunit_event(GdUnitEvent.new().deserialize(data))


	func _on_gdunit_event(event: GdUnitEvent):
		match event.type():
			GdUnitEvent.INIT:
				_report = GdUnitHtmlReport.new(_report_dir)
			GdUnitEvent.STOP:
				if _report == null:
					_report = GdUnitHtmlReport.new(_report_dir)
				var report_path := _report.write()
				_report.delete_history(_report_max)
				JUnitXmlReport.new(_report._report_path, _report.iteration()).write(_report)
				_console.prints_color(
					"Total test suites: %s" % _report.suite_count(),
					Color.DARK_SALMON
				).prints_color(
					"Total test cases:  %s" % _report.test_count(),
					Color.DARK_SALMON
				).prints_color(
					"Total time:        %s" % LocalTime.elapsed(_report.duration()),
					Color.DARK_SALMON
				).prints_color(
					"Open Report at: file://%s" % report_path,
					Color.CORNFLOWER_BLUE
				)
			GdUnitEvent.TESTSUITE_BEFORE:
				_report.add_testsuite_report(
					GdUnitTestSuiteReport.new(event.resource_path(), event.suite_name())
				)
			GdUnitEvent.TESTSUITE_AFTER:
				_report.update_test_suite_report(
					event.resource_path(),
					event.elapsed_time(),
					event.is_error(),
					event.is_failed(),
					event.is_warning(),
					event.is_skipped(),
					event.skipped_count(),
					event.failed_count(),
					event.orphan_nodes(),
					event.reports()
				)
			GdUnitEvent.TESTCASE_BEFORE:
				_report.add_testcase_report(
					event.resource_path(),
					GdUnitTestCaseReport.new(
						event.resource_path(),
						event.suite_name(),
						event.test_name()
					)
				)
			GdUnitEvent.TESTCASE_AFTER:
				var test_report := GdUnitTestCaseReport.new(
					event.resource_path(),
					event.suite_name(),
					event.test_name(),
					event.is_error(),
					event.is_failed(),
					event.failed_count(),
					event.orphan_nodes(),
					event.is_skipped(),
					event.reports(),
					event.elapsed_time()
				)
				_report.update_testcase_report(event.resource_path(), test_report)
		print_status(event)


	func report_exit_code(report: GdUnitHtmlReport) -> int:
		if report.error_count() + report.failure_count() > 0:
			_console.prints_color("Exit code: %d" % RETURN_ERROR, Color.FIREBRICK)
			return RETURN_ERROR
		if report.orphan_count() > 0:
			_console.prints_color("Exit code: %d" % RETURN_WARNING, Color.GOLDENROD)
			return RETURN_WARNING
		_console.prints_color("Exit code: %d" % RETURN_SUCCESS, Color.DARK_SALMON)
		return RETURN_SUCCESS


	func print_status(event: GdUnitEvent) -> void:
		match event.type():
			GdUnitEvent.TESTSUITE_BEFORE:
				_console.prints_color(
					"Run Test Suite %s " % event.resource_path(),
					Color.ANTIQUE_WHITE
				)
			GdUnitEvent.TESTCASE_BEFORE:
				_console.print_color(
					"	Run Test: %s > %s :" % [event.resource_path(), event.test_name()],
					Color.ANTIQUE_WHITE
				).prints_color(
					"STARTED",
					Color.FOREST_GREEN
				).save_cursor()
			GdUnitEvent.TESTCASE_AFTER:
				#_console.restore_cursor()
				_console.print_color(
					"	Run Test: %s > %s :" % [event.resource_path(), event.test_name()],
					Color.ANTIQUE_WHITE
				)
				_print_status(event)
				_print_failure_report(event.reports())
			GdUnitEvent.TESTSUITE_AFTER:
				_print_failure_report(event.reports())
				_print_status(event)
				_console.prints_color(
					"Statistics: | %d tests cases | %d error | %d failed | %d skipped | %d orphans |\n"
					% [
						_report.test_count(),
						_report.error_count(),
						_report.failure_count(),
						_report.skipped_count(),
						_report.orphan_count()
					],
					Color.ANTIQUE_WHITE
				)


	func _print_failure_report(reports: Array) -> void:
		for report in reports:
			if (
				report.is_failure()
				or report.is_error()
				or report.is_warning()
				or report.is_skipped()
			):
				_console.prints_color(
					"	Report:",
					Color.DARK_TURQUOISE, CmdConsole.BOLD | CmdConsole.UNDERLINE
				)
				var text = GdUnitTools.richtext_normalize(str(report))
				for line in text.split("\n"):
					_console.prints_color("		%s" % line, Color.DARK_TURQUOISE)
		_console.new_line()


	func _print_status(event: GdUnitEvent) -> void:
		if event.is_skipped():
			_console.print_color("SKIPPED", Color.GOLDENROD, CmdConsole.BOLD | CmdConsole.ITALIC)
		elif event.is_failed() or event.is_error():
			_console.print_color("FAILED", Color.FIREBRICK, CmdConsole.BOLD)
		elif event.orphan_nodes() > 0:
			_console.print_color("PASSED", Color.GOLDENROD, CmdConsole.BOLD | CmdConsole.UNDERLINE)
		else:
			_console.print_color("PASSED", Color.FOREST_GREEN, CmdConsole.BOLD)
		_console.prints_color(
			" %s" % LocalTime.elapsed(event.elapsed_time()), Color.CORNFLOWER_BLUE
		)


var _cli_runner: CLIRunner


func _initialize():
	if Engine.get_version_info().hex < 0x40100:
		prints("GdUnit4 requires a minimum of Godot 4.1.x Version!")
		quit(CLIRunner.RETURN_ERROR_GODOT_VERSION_NOT_SUPPORTED)
		return
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED)
	_cli_runner = CLIRunner.new()
	root.add_child(_cli_runner)


# do not use print statements on _finalize it results in random crashes
#func _finalize():
#	prints("Finallize ..")
#	prints("-Orphan nodes report-----------------------")
#	Window.print_orphan_nodes()
#	prints("Finallize .. done")
