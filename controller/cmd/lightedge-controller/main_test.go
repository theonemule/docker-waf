package main

import "testing"

func TestPolicyErrorOrderIndependent(t *testing.T) {
	for _, reasons := range [][]string{
		{"Pending", "TargetNotAccepted", "InvalidPolicy"},
		{"InvalidPolicy", "Pending", "TargetNotAccepted"},
		{"TargetNotAccepted", "InvalidPolicy", "Pending"},
	} {
		combined := map[string]string{}
		for _, r := range reasons {
			mergePolicyError(combined, "apps/policy", r)
		}
		if combined["apps/policy"] != "InvalidPolicy" {
			t.Fatal(combined)
		}
	}
}
