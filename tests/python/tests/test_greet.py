from test_app import greet


def test_greet() -> None:
    assert greet() == "hello"
