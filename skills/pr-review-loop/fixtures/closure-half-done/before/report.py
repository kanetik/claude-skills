from client import fetch


def summary(url):
    return len(fetch(url))
