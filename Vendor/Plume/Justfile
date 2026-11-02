set dotenv-load

lint:
    swiftlint lint Sources

lint-fix:
    swiftlint lint --fix Sources

format:
    swift format --recursive --in-place Sources

format-check:
    swift format lint --recursive Sources

build:
    swift build -c release

test:
    swift test

clean:
    swift package clean
    rm -rf .build .swiftpm
