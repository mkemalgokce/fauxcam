DYLIB := dist/libFaux.dylib
FIXTURE_BUNDLE_ID ?= com.fauxcam.fixture
DEVICE ?= booted

.PHONY: dylib verify doctor fixture smoke test clean

dylib:
	./Scripts/build-dylib.sh

verify: dylib
	./Scripts/verify-dylib.sh "$(DYLIB)"

doctor: dylib
	swift run faux doctor "$(DYLIB)"

fixture:
	./Scripts/build-fixture.sh

smoke: dylib fixture
	xcrun simctl install $(DEVICE) "Fixture/FauxFixture.app"
	SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$(PWD)/$(DYLIB)" \
		xcrun simctl launch --terminate-running-process $(DEVICE) $(FIXTURE_BUNDLE_ID)
	xcrun simctl spawn $(DEVICE) log show --predicate 'subsystem == "com.fauxcam"' --style compact --info --debug --last 30s

test:
	swift test

clean:
	rm -rf dist .build .build-faux Fixture/build Fixture/FauxFixture.app
