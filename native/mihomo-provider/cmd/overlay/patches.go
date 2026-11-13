package main

const boundaryImport = "\n\t\"proxima.local/mihomo-provider/boundary\"\n"

var patches = []patch{
	{
		path: "adapter/provider/parser.go",
		hash: "36e671da555fa913e5e49be05477e7de8c4fa75b010d2fb67e7404670e63d5ab",
		edits: []edit{
			{"import (\n", "import (\n" + boundaryImport},
			{"case \"file\":\n\t\tpath := C.Path.Resolve(schema.Path)", "case \"file\":\n\t\tif err := boundary.CheckPath(schema.Path); err != nil { return nil, err }\n\t\tpath := C.Path.Resolve(schema.Path)"},
			{"case \"http\":\n", "case \"http\":\n\t\tif err := boundary.URL(schema.URL); err != nil { return nil, err }\n\t\tif schema.Path != \"\" { if err := boundary.CheckPath(schema.Path); err != nil { return nil, err } }\n"},
		},
	},
	{
		path: "rules/provider/parse.go",
		hash: "c3aa47b9edf78a29035d616b0ab498d02cabf10b92d1ab093766e9faa1fa41e5",
		edits: []edit{
			{"import (\n", "import (\n" + boundaryImport},
			{"case \"file\":\n\t\tpath := C.Path.Resolve(schema.Path)", "case \"file\":\n\t\tif err := boundary.CheckPath(schema.Path); err != nil { return nil, err }\n\t\tpath := C.Path.Resolve(schema.Path)"},
			{"case \"http\":\n", "case \"http\":\n\t\tif err := boundary.URL(schema.URL); err != nil { return nil, err }\n\t\tif schema.Path != \"\" { if err := boundary.CheckPath(schema.Path); err != nil { return nil, err } }\n"},
		},
	},
	{
		path: "component/resource/vehicle.go",
		hash: "2dd10d1b7ed495c81a140c99f14c96048b11bd9b14079e84f5ef261f673b2050",
		edits: []edit{
			{"import (\n", "import (\n" + boundaryImport},
			{"\t\"path/filepath\"\n", ""},
			{`	dir := filepath.Dir(path)

	if _, err := os.Stat(dir); os.IsNotExist(err) {
		if err := os.MkdirAll(dir, dirMode); err != nil {
			return err
		}
	}

	return os.WriteFile(path, buf, fileMode)`, "\treturn boundary.WriteFile(path, buf)"},
			{"buf, err = os.ReadFile(f.path)", "buf, err = boundary.ReadFile(f.path)"},
			{"mihomoHttp.WithSpecialProxy(h.proxy))", "mihomoHttp.WithSpecialProxy(h.proxy), mihomoHttp.WithURLPolicy(boundary.URL))"},
		},
	},
	{
		path: "component/resource/fetcher.go",
		hash: "647fdd5906c41202974577ff96a00ebc6bda441ae3e9d7717037cedff4eee903",
		edits: []edit{
			{"import (\n", "import (\n" + boundaryImport},
			{"\t\"os\"\n", ""},
			{"\t\"github.com/metacubex/fswatch\"\n", ""},
			{"watcher      *fswatch.Watcher", "workers      sync.WaitGroup"},
			{"os.Stat(f.vehicle.Path())", "boundary.Stat(f.vehicle.Path())"},
			{"buf, err := os.ReadFile(f.vehicle.Path())", "buf, err := boundary.ReadFile(f.vehicle.Path())\n\t\tif err != nil { return lo.Empty[V](), err }"},
			{"buf, err := io.ReadAll(file)", "buf, err := io.ReadAll(file)\n\t\t\tif err != nil { return lo.Empty[V](), err }"},
			{"_ = os.Chtimes(f.vehicle.Path(), now, now)", "if err := boundary.Chtimes(f.vehicle.Path(), now, now); err != nil { return lo.Empty[V](), false, err }"},
			{`	if f.watcher != nil {
		_ = f.watcher.Close()
	}`, "\tf.workers.Wait()"},
			{`	if f.vehicle.Type() == P.File {
		f.watcher, err = fswatch.NewWatcher(fswatch.Options{
			Path:     []string{f.vehicle.Path()},
			Callback: f.updateCallback,
		})
		if err != nil {
			return err
		}
		err = f.watcher.Start()
		if err != nil {
			return err
		}
	} else if f.interval > 0 {
		go f.pullLoop(forceUpdate)
	}`, `	if f.interval > 0 {
		f.workers.Add(1)
		go func() { defer f.workers.Done(); f.pullLoop(forceUpdate) }()
	}`},
			{"ctx, cancel := context.WithCancel(context.Background())", `// File providers retain automatic reload without pathname-based watches.
	if vehicle.Type() == P.File { interval = time.Second }
	ctx, cancel := context.WithCancel(context.Background())`},
		},
	},
	{
		path: "component/http/http.go",
		hash: "908b28230f08850d37816a0d1e2920ba5b3ed1d19f32cdc1892ca3078b359a1d",
		edits: []edit{
			{"\t\"context\"\n", "\t\"context\"\n\t\"errors\"\n"},
			{"method = strings.ToUpper(method)", `if opt.urlPolicy != nil {
		if err := opt.urlPolicy(url); err != nil { return nil, err }
	}
	method = strings.ToUpper(method)`},
			{"client := http.Client{Transport: transport}", `client := http.Client{Transport: transport}
	if opt.urlPolicy != nil {
		client.CheckRedirect = func(req *http.Request, via []*http.Request) error {
			if err := opt.urlPolicy(req.URL.String()); err != nil { return err }
			if len(via) >= 10 { return errors.New("stopped after 10 redirects") }
			return nil
		}
	}`},
			{"type option struct {\n", "type option struct {\n\turlPolicy func(string) error\n"},
			{"func WithSpecialProxy(name string) Option {", `// WithURLPolicy checks the initial request and every redirect before sending.
func WithURLPolicy(policy func(string) error) Option {
	return func(opt *option) { opt.urlPolicy = policy }
}

func WithSpecialProxy(name string) Option {`},
		},
	},
	{
		path: "component/profile/cachefile/cache.go",
		hash: "cf48b5ba8d034847073c189a755b63bfbce43e1d1e0cebe3c2ce72267fd8cb65",
		edits: []edit{
			{"import (\n", "import (\n" + boundaryImport},
			{"bbolt.Options{Timeout: time.Second, NoStatistics: true}", "bbolt.Options{Timeout: time.Second, NoStatistics: true, OpenFile: boundary.OpenFile}"},
			{"os.Remove(C.Path.Cache())", "boundary.Remove(C.Path.Cache())"},
		},
	},
	{
		path: "rules/bundle/bundle.go",
		hash: "86410c9d8b58e2781a9d9316e894f918b991a98e75a9a8b0d7b479de30d7dfc8",
		edits: []edit{
			{"import (\n", "import (\n" + boundaryImport},
			{`	r, err := sevenzip.OpenReader(C.Path.BundleMRS())
	if err != nil {
		return nil, fmt.Errorf("open bundle file error: %w", err)
	}`, `	archive, err := boundary.OpenArchive(C.Path.BundleMRS())
	if err != nil { return nil, fmt.Errorf("open bundle file error: %w", err) }
	r, err := sevenzip.NewReader(archive, archive.Size())
	if err != nil { return nil, errors.Join(err, archive.Close()) }`},
			{`		_ = r.Close()
		return nil, fmt.Errorf("open path in bundle file error: %w", err)`, `		return nil, errors.Join(fmt.Errorf("open path in bundle file error: %w", err), archive.Close())`},
			{"return file{f, r}, nil", "return file{f, archive}, nil"},
		},
	},
	{
		path: "constant/path.go",
		hash: "809392076d9ee49be02d42b0177e0db6045b0a118da52fb6f816a018e0125524",
		edits: []edit{
			{"import (\n", "import (\n" + boundaryImport},
			{`func (p *path) BundleMRS() string {
	files, err := os.ReadDir(p.homeDir)`, `func (p *path) BundleMRS() string {
	files, err := boundary.ReadDir(p.homeDir)`},
		},
	},
}
