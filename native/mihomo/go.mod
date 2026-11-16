module proxima.local/mihomo

go 1.25.0

require (
	github.com/metacubex/mihomo v1.19.33
	github.com/stretchr/testify v1.12.1
	golang.org/x/sys v0.30.0
)

require (
	github.com/bahlo/generic-list-go v0.2.0 // indirect
	github.com/gofrs/uuid/v5 v5.4.0 // indirect
	github.com/metacubex/bart v0.29.0 // indirect
	github.com/metacubex/randv2 v0.2.0 // indirect
	github.com/metacubex/sing v0.5.8 // indirect
	github.com/metacubex/tfo-go v0.0.0-20260623020846-376a77860b8c // indirect
	github.com/miekg/dns v1.1.63 // indirect
	github.com/openacid/low v0.1.21 // indirect
	github.com/samber/lo v1.53.0 // indirect
	github.com/sirupsen/logrus v1.9.4 // indirect
	go.yaml.in/yaml/v3 v3.0.5 // indirect
	golang.org/x/exp v0.0.0-20240904232852-e7e105dedf7e // indirect
	golang.org/x/mod v0.20.0 // indirect
	golang.org/x/net v0.35.0 // indirect
	golang.org/x/sync v0.11.0 // indirect
	golang.org/x/text v0.22.0 // indirect
	golang.org/x/tools v0.24.0 // indirect
)

// Mihomo's dependency replacement is not inherited by importing modules.
replace google.golang.org/protobuf => github.com/metacubex/protobuf-go v0.0.0-20260306035419-7ceee0674686
