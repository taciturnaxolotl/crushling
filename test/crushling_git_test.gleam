import crushling/git
import crushling/repo_url

pub fn repo_url_test() {
  let assert "owner/repo" = repo_url.name("https://github.com/owner/repo.git")
  let assert "owner/repo" = repo_url.name("git@github.com:owner/repo.git")
  let assert "https://github.com/owner/repo" =
    repo_url.web("git@github.com:owner/repo.git")
  let assert "https://github.com/owner/repo" =
    repo_url.web("https://github.com/owner/repo.git")
  let assert "https://github.com/owner/repo" =
    repo_url.web("ssh://git@github.com/owner/repo.git")
  // tangled: the owner is a DID and the knot serves no page there.
  let tangled = "git@knot.dunkirk.sh:did:plc:krxbvxvis5skq7jj6eot23ul/crushling"
  let assert "crushling" = repo_url.name(tangled)
  let assert "" = repo_url.web(tangled)
  let assert "source" = repo_url.name("/tmp/x/source")
}

pub fn repo_info_test() {
  let assert git.RepoInfo(
    url: "https://github.com/owner/repo",
    branch: "fix",
    base: "main",
  ) = git.parse_repo_info("https://github.com/owner/repo\nfix\nmain\n")
}

pub fn push_state_test() {
  let shell = fn(_) { Ok("2\norigin/fix\n3\n") }
  let assert git.PushState(2, "origin/fix", Ok(3)) = git.push_state(shell, ".")
  let shell = fn(_) { Ok("0\n\n\n") }
  let assert git.PushState(0, "", Error(Nil)) = git.push_state(shell, ".")
}

pub fn find_names_a_repo_test() {
  let shell = fn(script) {
    case script {
      "for d in" <> _ -> Ok("./one\n./two\n")
      "cd './one' 2>/dev/null" <> _ -> Ok("yes\n")
      "cd './one' && git remote" <> _ ->
        Ok("git@github.com:o/one.git\nmain\nmain")
      _ -> Error(Nil)
    }
  }
  let assert Ok(git.Found(dir: "./one", name: "o/one", ..)) =
    git.find(shell, "")
  let assert Error(_) = git.find(shell, "./two")
}
