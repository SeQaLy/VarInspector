package main

import "fmt"

// package-level exported / unexported
var GlobalCounter int = 0
var localSecret string = "hidden"
const MaxRetries = 3
const minWait = 100

var (
	ExportedA int
	internalB string = "x"
	ExportedC, ExportedD float64
)

// Config is an exported struct
type Config struct {
	Name      string
	Port      int
	enabled   bool
	Tags      []string
	internalX map[string]int
}

func Compute(input int, factor float64) (result int, err error) {
	total := input * 2
	var temp float64 = factor + 1.0
	scaled := total
	return scaled, nil
}

func (c *Config) Apply(prefix string) {
	localName := prefix + c.Name
	fmt.Println(localName)
}
