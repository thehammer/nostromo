import XCTest
import Foundation

// `StagingDestructivePatterns` and `StagingHazards`: what the app says about a command's text, with no views.
//
//   * The fixed destructive-pattern list (PRD SR6): a table of positive and negative cases for every pattern.
//     A match only labels the row (and, in a production-treated pane, asks first). Every label ends with
//     "No label does not mean safe."; no code path produces a safe, green or check-mark label.
//   * History expansion: the same rule the daemon applies (the cases here are the ones in
//     `tests/fixtures/terminal_staging/hazards.json`).
//   * The look-alike non-ASCII label: code points and names, at most three, then "and N more".

final class StagingHazardsTests: XCTestCase {

    // MARK: Destructive patterns

    func testEveryPatternMatchesItsPositiveCases() {
        let positives: [(command: String, names: [String])] = [
            ("rm -rf /tmp/x", ["rm -rf"]), ("rm -fr /tmp/x", ["rm -rf"]), ("rm -Rf /tmp/x", ["rm -rf"]),
            ("rm -r -f x", ["rm -rf"]), ("rm -f -r x", ["rm -rf"]),
            ("rm --recursive --force x", ["rm -rf", "--force"]), ("rm -r --force x", ["rm -rf", "--force"]), ("sudo rm -rf x && ls", ["rm -rf"]),
            ("ls; rm -rf x", ["rm -rf"]),
            ("DROP TABLE users", ["DROP"]), ("drop table users", ["DROP"]), ("psql -c 'drop database x'", ["DROP"]),
            ("TRUNCATE TABLE users", ["TRUNCATE"]), ("truncate users", ["TRUNCATE"]),
            ("DELETE FROM users", ["DELETE FROM without WHERE"]), ("delete from users;", ["DELETE FROM without WHERE"]),
            ("php artisan migrate:fresh", ["migrate:fresh"]), ("php artisan db:wipe", ["db:wipe"]),
            ("php artisan queue:flush", ["queue:flush"]), ("php artisan cache:clear", ["cache:clear"]),
            ("PHP ARTISAN MIGRATE:FRESH", ["migrate:fresh"]),
            ("git push --force", ["--force"]), ("git push --force-with-lease", ["--force"]), ("composer install --force", ["--force"]),
            ("kill -9 123", ["kill -9"]), ("pkill -9 x", ["kill -9"]), ("killall -KILL x", ["kill -9"]),
            ("kill -SIGKILL 1", ["kill -9"]), ("kill -s 9 1", ["kill -9"]), ("kill -s KILL 1", ["kill -9"]),
            ("kill -s SIGKILL 1", ["kill -9"]),
            ("php artisan queue:flush && php artisan cache:clear", ["queue:flush", "cache:clear"]),
            ("rm -rf x; DROP TABLE y", ["rm -rf", "DROP"]),
        ]
        for (command, names) in positives {
            XCTAssertEqual(StagingDestructivePatterns.matches(command), names, command)
        }
    }

    func testTheNegativeCasesMatchNothing() {
        let negatives = [
            "ls -la", "git push", "git status", "rm x", "rm -r x", "rm -f x", "rm -v x", "echo -rf",
            "rm x | grep -rf y", "rm x; echo -rf", "DELETE FROM users WHERE id = 1", "delete from t where x=1",
            "echo drops", "echo truncated", "git push --forceful", "kill 123", "kill -15 1", "kill -s 15 1",
            "pkill -f x", "cat migrate", "php artisan cache:forget x",
        ]
        for command in negatives {
            XCTAssertEqual(StagingDestructivePatterns.matches(command), [], command)
        }
    }

    func testTheListIsExactlyTheFixedOneInOrder() {
        XCTAssertEqual(StagingDestructivePatterns.names, ["rm -rf", "DROP", "TRUNCATE", "DELETE FROM without WHERE", "migrate:fresh",
                                                          "db:wipe", "queue:flush", "cache:clear", "--force", "kill -9",
                                                          "migrate:refresh", "migrate:reset", "migrate:rollback", "kubectl delete",
                                                          "kubectl drain", "helm uninstall", "terraform destroy", "aws delete/terminate",
                                                          "aws s3 rm/rb", "dd of=", "mkfs", "shred", "> file", "find -delete",
                                                          "xargs/piped rm", "queue:clear", "horizon:clear", "optimize:clear",
                                                          "FLUSHALL/FLUSHDB", "stop/shutdown"])
        XCTAssertEqual(StagingDestructivePatterns.names.count, 30)
        XCTAssertEqual(Set(StagingDestructivePatterns.names).count, 30, "the names are unique")
    }

    func testEveryPatternLabelSaysNoLabelDoesNotMeanSafeAndNothingSaysSafe() {
        XCTAssertEqual(StagingHazards.destructiveLabel(["queue:flush"], production: true),
                       "\u{26A0} Matches a destructive pattern (queue:flush). Insert asks first. No label does not mean safe.")
        XCTAssertEqual(StagingHazards.destructiveLabel(["queue:flush"], production: false),
                       "\u{26A0} Matches a destructive pattern (queue:flush). No label does not mean safe.")
        XCTAssertEqual(StagingHazards.destructiveLabel(["rm -rf", "DROP"], production: true),
                       "\u{26A0} Matches a destructive pattern (rm -rf, DROP). Insert asks first. No label does not mean safe.")
        XCTAssertNil(StagingHazards.destructiveLabel([], production: true), "no match, no label")
        for production in [true, false] {
            for name in StagingDestructivePatterns.names {
                let label = StagingHazards.destructiveLabel([name], production: production) ?? ""
                XCTAssertTrue(label.contains("No label does not mean safe."), label)
                XCTAssertFalse(label.replacingOccurrences(of: "No label does not mean safe.", with: "").lowercased().contains("safe"), label)
                XCTAssertFalse(label.contains("\u{2713}") || label.contains("\u{2705}"), label)
            }
        }
    }

    // MARK: Wrapped, split and abbreviated forms (M2, S4, P4)

    func testRmRfIsSeenThroughWrapping() {
        let wrapped = [
            "bash -c 'rm -rf /srv/app/cache'", "sh -c \"rm -rf x\"", "echo $(rm -rf x)", "echo `rm -rf x`", "(rm -rf x)",
            "{ rm -rf x; }", "\\rm -rf x", "\"rm\" -rf x", "r''m -rf x", "command rm -rf x", "/bin/rm -rf x", "env rm -rf x",
            "rm -r --forc x", "rm --recurs -f x", "rm -rf x", "ls & rm -rf x", "xargs rm -rf",
        ]
        for command in wrapped {
            XCTAssertTrue(StagingDestructivePatterns.matches(command).contains("rm -rf"), command)
        }
        XCTAssertFalse(StagingDestructivePatterns.matches("bash -c 'rm x'").contains("rm -rf"))
        XCTAssertFalse(StagingDestructivePatterns.matches("echo \"rm\" -r x").contains("rm -rf"))
    }

    func testLaravelAbbreviationsAndSplitWordsMatch() {
        let cases: [(String, String)] = [
            ("php artisan ca:cl", "cache:clear"), ("php artisan q:fl", "queue:flush"), ("php artisan mi:fr", "migrate:fresh"),
            ("php artisan db:w", "db:wipe"), ("php artisan migrate:fre''sh", "migrate:fresh"),
            ("php artisan cache:cle\\ar", "cache:clear"), ("php artisan \"queue\":flush", "queue:flush"),
        ]
        for (command, name) in cases {
            XCTAssertTrue(StagingDestructivePatterns.matches(command).contains(name), command)
        }
        XCTAssertEqual(StagingDestructivePatterns.matches("php artisan cache:forget x"), [])
        XCTAssertEqual(StagingDestructivePatterns.matches("php artisan route:list"), [])
    }

    func testSqlCommentsAndShortKillAndForceForms() {
        XCTAssertTrue(StagingDestructivePatterns.matches("mysql -e 'DROP/**/TABLE users'").contains("DROP"))
        XCTAssertTrue(StagingDestructivePatterns.matches("DELETE/**/FROM users").contains("DELETE FROM without WHERE"))
        XCTAssertTrue(StagingDestructivePatterns.matches("kill -n 9 123").contains("kill -9"))
        XCTAssertTrue(StagingDestructivePatterns.matches("git push --forc").contains("--force"))
        XCTAssertEqual(StagingDestructivePatterns.matches("git log --format=x"), [])
    }

    func testEachDeleteStatementIsCheckedOnItsOwn() {
        for command in ["DELETE FROM a WHERE id=1; DELETE FROM b", "DELETE FROM a; SELECT * FROM b WHERE x = 1",
                        "delete from a where id=1; delete from b; select 1"] {
            XCTAssertTrue(StagingDestructivePatterns.matches(command).contains("DELETE FROM without WHERE"), command)
        }
        XCTAssertEqual(StagingDestructivePatterns.matches("DELETE FROM a WHERE id=1; DELETE FROM b WHERE id=2"), [])
    }

    // MARK: The fifteen families added after the first ten (kubectl, helm, terraform, aws, dd, mkfs, shred, `> file`, find, xargs, ...)
    //
    // Each family: wrapped, quoted, sudo'd, piped and absolute-path variants are still seen, and the read-only
    // look-alikes are not. The list is conservative: an ambiguous command MATCHES (the user is asked to confirm).
    // The daemon's `destructive.rs` is held to the same cases (`src/terminal/staging/tests/destructive.rs`).

    /// Every command carries `name` (and possibly other names).
    private func assertAll(_ name: String, _ commands: [String], file: StaticString = #filePath, line: UInt = #line) {
        for command in commands {
            let found = StagingDestructivePatterns.matches(command)
            XCTAssertTrue(found.contains(name), "\(command) should be labelled \(name), got \(found)", file: file, line: line)
        }
    }

    /// No command matches anything.
    private func assertNone(_ commands: [String], file: StaticString = #filePath, line: UInt = #line) {
        for command in commands {
            XCTAssertEqual(StagingDestructivePatterns.matches(command), [], command, file: file, line: line)
        }
    }

    /// No command carries `name` (other names are not this family's business).
    private func assertNotLabelled(_ name: String, _ commands: [String], file: StaticString = #filePath, line: UInt = #line) {
        for command in commands {
            let found = StagingDestructivePatterns.matches(command)
            XCTAssertFalse(found.contains(name), "\(command) must not be labelled \(name), got \(found)", file: file, line: line)
        }
    }

    func testNewMigrateRefreshResetRollbackFamilyIsSeenThroughWrapping() {
        // Like migrate:fresh: the literal name, any case, and the Laravel abbreviation.
        assertAll("migrate:refresh", [#"php artisan migrate:refresh --seed"#, #"PHP ARTISAN MIGRATE:REFRESH"#, #"php artisan mi:ref"#])
        assertAll("migrate:reset", [#"php artisan migrate:reset"#, #"PHP ARTISAN MIGRATE:RESET"#, #"php artisan mi:rese"#])
        assertAll("migrate:rollback", [#"php artisan migrate:rollback --step=1"#, #"PHP ARTISAN MIGRATE:ROLLBACK"#,
                                       #"php artisan migrate:rol"#, #"php artisan mi:ro"#])
        // migrate resets are seen through wrapping quoting and sudo
        assertAll(#"migrate:refresh"#, [
            #"bash -c 'php artisan migrate:refresh'"#,
            #"php artisan migrate:refre''sh"#,
            #"echo $(php artisan migrate:refresh)"#,
            #"sudo -u www-data php artisan migrate:refresh"#,
        ])
        assertAll(#"migrate:rollback"#, [
            #"php artisan "migrate":rollback"#,
            #"php artisan down && php artisan migrate:rollback; php artisan up"#,
            #"sudo -u www-data php artisan migrate:rollback --force"#,
        ])
        assertAll(#"migrate:reset"#, [
            #"php artisan migrate:res\et"#,
        ])
        XCTAssertEqual(StagingDestructivePatterns.matches(#"sudo -u www-data php artisan migrate:rollback --force"#), ["--force", "migrate:rollback"])
        // migrate abbreviations that fit several commands label all of them
        XCTAssertEqual(StagingDestructivePatterns.matches(#"php artisan mi:re"#), ["migrate:refresh", "migrate:reset"])
        XCTAssertEqual(StagingDestructivePatterns.matches(#"php artisan mi:r"#), ["migrate:refresh", "migrate:reset", "migrate:rollback"])
        // migrate look alikes are not resets
        assertNone([
            #"php artisan migrate:status"#,
            #"php artisan migrate"#,
            #"php artisan migrate --pretend"#,
            #"php artisan migrate:install"#,
            #"php artisan make:request StoreUser"#,
            #"php artisan make:migration add_x_to_users"#,
            #"php artisan route:list"#,
        ])
    }

    func testNewKubectlFamilyIsSeenThroughWrapping() {
        // kubectl delete is caught wherever the program sits
        assertAll(#"kubectl delete"#, [
            #"kubectl delete pod web-1"#,
            #"kubectl delete -f deploy.yaml"#,
            #"kubectl -n prod delete pod web-1"#,
            #"kubectl --namespace=prod delete deployment web"#,
            #"KUBECTL delete ns prod"#,
            #"/usr/local/bin/kubectl delete pod web-1"#,
            #"sudo kubectl delete pod web-1"#,
            #"env KUBECONFIG=/x kubectl delete pod web-1"#,
            #"KUBECONFIG=/x kubectl delete pod web-1"#,
            #"command kubectl delete pod web-1"#,
            #"time kubectl delete pod web-1"#,
            #"nohup kubectl delete pod web-1"#,
            #"exec kubectl delete pod web-1"#,
            #"kubectl get pods && kubectl delete pod web-1"#,
            #"echo go; kubectl delete pod web-1"#,
            #"false || kubectl delete pod web-1"#,
            #"echo web-1 | kubectl delete pod web-1"#,
            #"k''ubectl delete pod web-1"#,
            #""kubectl" delete pod web-1"#,
            #"\kubectl delete pod web-1"#,
            #"kubectl del\ete pod web-1"#,
            #"kubectl${IFS}delete${IFS}pod${IFS}web-1"#,
            #"bash -c 'kubectl delete pod web-1'"#,
            #"echo $(kubectl delete pod web-1)"#,
            #"echo `kubectl delete pod web-1`"#,
            #"(kubectl delete pod web-1)"#,
            #"{ kubectl delete pod web-1; }"#,
        ])
        // kubectl drain is caught wherever the program sits
        assertAll(#"kubectl drain"#, [
            #"kubectl drain node-1 --ignore-daemonsets"#,
            #"kubectl --context prod drain node-1"#,
            #"sudo kubectl drain node-1"#,
            #"/usr/bin/kubectl drain node-1"#,
            #"bash -c "kubectl drain node-1""#,
            #"kubectl dr''ain node-1"#,
        ])
        XCTAssertEqual(StagingDestructivePatterns.matches(#"kubectl drain node-1; kubectl delete node node-1"#), ["kubectl delete", "kubectl drain"])
        // kubectl read only look alikes match nothing
        assertNone([
            #"kubectl get pods"#,
            #"kubectl describe pod web-1"#,
            #"kubectl logs web-1"#,
            #"kubectl apply -f x.yaml"#,
            #"kubectl get pod delete-me"#,
            #"kubectl get node drain-me"#,
            #"kubectl get pods; echo delete"#,
        ])
    }

    func testNewHelmFamilyIsSeenThroughWrapping() {
        // helm uninstall and its aliases are caught
        assertAll(#"helm uninstall"#, [
            #"helm uninstall web"#,
            #"helm delete web"#,
            #"helm del web"#,
            #"helm un web"#,
            #"helm -n prod uninstall web"#,
            #"sudo helm uninstall web"#,
            #"/usr/local/bin/helm uninstall web"#,
            #"HELM uninstall web"#,
            #"bash -c 'helm uninstall web'"#,
            #"helm list && helm uninstall web"#,
            #"he''lm uninstall web"#,
            #"helm${IFS}uninstall${IFS}web"#,
            #"echo $(helm uninstall web)"#,
        ])
        // helm read only look alikes match nothing
        assertNone([
            #"helm list"#,
            #"helm install web ./chart"#,
            #"helm upgrade web ./chart"#,
            #"helm status web"#,
            #"helm list --uninstalling"#,
            #"helm list; echo uninstall"#,
        ])
    }

    func testNewTerraformFamilyIsSeenThroughWrapping() {
        // terraform destroy and the ambiguous destroying flags are caught
        assertAll(#"terraform destroy"#, [
            #"terraform destroy"#,
            #"terraform destroy -auto-approve"#,
            #"tofu destroy"#,
            #"terragrunt destroy"#,
            #"terragrunt run-all destroy"#,
            #"terraform apply -destroy"#,
            #"terraform apply --destroy"#,
            #"terraform plan -destroy"#,
            #"terraform apply -replace=aws_instance.web"#,
            #"terraform apply -replace aws_instance.web"#,
            #"tofu apply -replace=aws_instance.web"#,
            #"terraform -chdir=infra destroy"#,
            #"terraform -chdir=infra apply -destroy"#,
            #"sudo terraform destroy"#,
            #"/usr/local/bin/terraform destroy"#,
            #"TF_LOG=debug terraform destroy"#,
            #"env TF_LOG=debug terraform destroy"#,
            #"TERRAFORM destroy"#,
            #"terraform apply -auto-approve && terraform destroy"#,
            #"bash -c 'terraform destroy'"#,
            #"terra''form destroy"#,
            #"terraform "destroy""#,
            #"\terraform destroy"#,
            #"terraform${IFS}destroy"#,
        ])
        // terraform read only and plain apply look alikes match nothing
        assertNone([
            #"terraform apply"#,
            #"terraform plan"#,
            #"terraform init"#,
            #"terraform apply -auto-approve"#,
            #"tofu validate"#,
            #"terraform fmt"#,
            #"terraform state list"#,
            #"terraform plan -out=tfplan"#,
            #"terraform plan; echo destroy"#,
        ])
    }

    func testNewAwsFamilyIsSeenThroughWrapping() {
        assertNotLabelled("aws s3 rm/rb", [#"aws s3 cp a.txt s3://b/a.txt"#, #"aws s3 cp s3://b/k ./out --recursive"#,
                                           #"aws s3 sync ./out s3://b"#, #"aws s3 sync ./out s3://b --dryrun"#,
                                           #"aws s3 mb s3://x"#, #"aws s3 ls s3://rm"#, #"aws s3 ls"#])
        // aws delete terminate remove deregister and purge verbs are caught
        assertAll(#"aws delete/terminate"#, [
            #"aws ec2 terminate-instances --instance-ids i-0abc"#,
            #"aws s3api delete-object --bucket b --key k"#,
            #"aws s3api delete-bucket --bucket b"#,
            #"aws iam remove-user-from-group --user-name u --group-name g"#,
            #"aws ecs deregister-task-definition --task-definition web:1"#,
            #"aws sqs purge-queue --queue-url q"#,
            #"aws rds delete-db-instance --db-instance-identifier x --skip-final-snapshot"#,
            #"aws --profile prod ec2 terminate-instances --instance-ids i-0abc"#,
            #"aws --region us-east-1 --profile prod ec2 terminate-instances --instance-ids i-0abc"#,
            #"AWS EC2 TERMINATE-INSTANCES --instance-ids i-0abc"#,
            #"sudo aws ec2 terminate-instances --instance-ids i-0abc"#,
            #"/usr/local/bin/aws ec2 terminate-instances --instance-ids i-0abc"#,
            #"AWS_PROFILE=prod aws ec2 terminate-instances --instance-ids i-0abc"#,
            #"env AWS_PROFILE=prod aws ec2 terminate-instances --instance-ids i-0abc"#,
            #"time aws ec2 terminate-instances --instance-ids i-0abc"#,
            #"aws ec2 describe-instances && aws ec2 terminate-instances --instance-ids i-0abc"#,
            #"a''ws ec2 terminate-instances --instance-ids i-0abc"#,
            #"aws ec2 "terminate-instances" --instance-ids i-0abc"#,
            #"\aws ec2 delete-volume --volume-id vol-0abc"#,
            #"aws ec2 termi\nate-instances --instance-ids i-0abc"#,
            #"bash -c 'aws ec2 terminate-instances --instance-ids i-0abc'"#,
            #"echo $(aws sqs purge-queue --queue-url q)"#,
            #"(aws iam delete-user --user-name u)"#,
            #"aws${IFS}ec2${IFS}terminate-instances${IFS}--instance-ids${IFS}i-0abc"#,
        ])
        // aws read only look alikes match nothing
        assertNone([
            #"aws ec2 describe-instances"#,
            #"aws s3 ls"#,
            #"aws s3api get-object --bucket b --key k out.bin"#,
            #"aws iam list-users"#,
            #"aws sts get-caller-identity"#,
            #"aws s3 ls s3://delete-me"#,
            #"aws logs filter-log-events --log-group-name g"#,
            #"aws ec2 describe-instances --filters Name=tag:x,Values=delete-me"#,
            #"aws ec2 describe-instances; echo terminate-instances"#,
        ])
        // aws s3 rm rb and sync with delete are caught
        assertAll(#"aws s3 rm/rb"#, [
            #"aws s3 rm s3://b/k"#,
            #"aws s3 rm s3://b/k --recursive"#,
            #"aws s3 rb s3://b --force"#,
            #"aws s3 rb s3://b"#,
            #"aws --profile prod s3 rm s3://b/k"#,
            #"aws s3 sync ./out s3://b --delete"#,
            #"aws s3 sync s3://a s3://b --delete --exact-timestamps"#,
            #"sudo aws s3 rm s3://b/k"#,
            #"/usr/local/bin/aws s3 rm s3://b/k"#,
            #"AWS_PROFILE=prod aws s3 rb s3://b"#,
            #"bash -c 'aws s3 rm s3://b/k'"#,
            #""aws" s3 "rm" s3://b/k"#,
            #"aws s3 r''m s3://b/k"#,
            #"aws${IFS}s3${IFS}rm${IFS}s3://b/k"#,
            #"aws s3 ls && aws s3 rm s3://b/k"#,
        ])
        XCTAssertEqual(StagingDestructivePatterns.matches(#"aws s3 rb s3://b --force"#), ["--force", "aws s3 rm/rb"])
        XCTAssertEqual(StagingDestructivePatterns.matches(#"aws s3 rm s3://b/k --recursive --force"#), ["rm -rf", "--force", "aws s3 rm/rb"])
        XCTAssertEqual(StagingDestructivePatterns.matches(#"aws s3 rm s3://b/k && aws ec2 terminate-instances --instance-ids i-0abc"#), ["aws delete/terminate", "aws s3 rm/rb"])
    }

    func testNewDdMkfsShredAndTruncateFamiliesAreSeenThroughWrapping() {
        // dd with an output file is caught and a read only dd is not
        assertAll(#"dd of="#, [
            #"dd if=/dev/zero of=/dev/sda bs=1M"#,
            #"dd of=/dev/sdb if=disk.img"#,
            #"DD IF=disk.img OF=/dev/sdb"#,
            #"sudo dd if=disk.img of=/dev/sdb"#,
            #"/bin/dd if=disk.img of=/dev/sdb"#,
            #"env LC_ALL=C dd if=disk.img of=/dev/sdb"#,
            #"time dd if=disk.img of=/dev/sdb"#,
            #"nohup dd if=disk.img of=/dev/sdb"#,
            #"cat disk.img | dd of=/dev/sdb"#,
            #"sync && dd if=disk.img of=/dev/sdb"#,
            #"bash -c 'dd if=/dev/zero of=/dev/sda'"#,
            #"echo $(dd if=a of=b)"#,
            #"d''d if=disk.img of=/dev/sdb"#,
            #"dd if=disk.img o''f=/dev/sdb"#,
            #"\dd if=disk.img of=/dev/sdb"#,
            #"dd${IFS}if=disk.img${IFS}of=/dev/sdb"#,
        ])
        assertNone([
            #"dd if=/dev/zero bs=1M count=1"#,
            #"echo odd of=x"#,
            #"ls of=x"#,
            #"dd if=disk.img bs=1 count=1; echo of=x"#,
        ])
        // mkfs and its variants are caught and look alikes are not
        assertAll(#"mkfs"#, [
            #"mkfs /dev/sdb1"#,
            #"mkfs.ext4 /dev/sdb1"#,
            #"/sbin/mkfs -t xfs /dev/sdb1"#,
            #"sudo mkfs.xfs /dev/sdb1"#,
            #"MKFS.EXT4 /dev/sdb1"#,
            #"mkfs.vfat -F 32 /dev/sdb1"#,
            #"X=1 mkfs.ext4 /dev/sdb1"#,
            #"echo go; mkfs.ext4 /dev/sdb1"#,
            #"bash -c 'mkfs.ext4 /dev/sdb1'"#,
            #"mk''fs.ext4 /dev/sdb1"#,
            #"/usr/sbin/mkfs.btrfs -f /dev/sdb1"#,
            #"mkfsx /dev/sdb1"#,
            #"mkfs.ext4${IFS}/dev/sdb1"#,
        ])
        assertNone([
            #"mkdir -p /tmp/x"#,
            #"mk"#,
            #"mktemp -d"#,
            #"echo mkf"#,
        ])
        // shred is caught and look alikes are not
        assertAll(#"shred"#, [
            #"shred -u secret.txt"#,
            #"shred -vzn 3 /dev/sdb"#,
            #"SHRED -u secret.txt"#,
            #"sudo shred -u secret.txt"#,
            #"/usr/bin/shred -u secret.txt"#,
            #"ls | xargs shred -u"#,
            #"bash -c 'shred -u secret.txt'"#,
            #"sh''red -u secret.txt"#,
            #"\shred secret.txt"#,
            #"echo go; shred secret.txt"#,
        ])
        assertNone([
            #"shredder --help"#,
            #"echo shreds"#,
            #"ls shred-notes.txt"#,
        ])
        // truncate the command is the truncate pattern
        XCTAssertEqual(StagingDestructivePatterns.matches(#"truncate -s 0 f"#), ["TRUNCATE"])
        XCTAssertEqual(StagingDestructivePatterns.matches(#"sudo truncate -s0 /var/log/app.log"#), ["TRUNCATE"])
    }

    func testNewTruncatingRedirectFamilyIsSeenThroughWrapping() {
        // a truncating redirection is caught in all its spellings
        assertAll(#"> file"#, [
            #": > file"#,
            #":> file"#,
            #"echo hi > out.txt"#,
            #"cat a >b"#,
            #"ls 2>err.log"#,
            #"cmd >| f"#,
            #"cmd >! f"#,
            #"echo x >& log"#,
            #"a &>log"#,
            #"> /var/log/app.log"#,
            #"echo x >$out"#,
            #"ls > /dev/nullx"#,
            #"ls > /DEV/NULL"#,
            #"ls > /Dev/Null"#,
            #"cmd > /dev/null > out.txt"#,
            #"echo a >(cat)"#,
            #"echo a >"#,
            #"sudo sh -c 'echo x > /etc/conf'"#,
            #"bash -c "cat a > b""#,
            #"echo $(echo x > f)"#,
            #"ls && echo x > f"#,
        ])
        // appends dups closes and redirections to the bit buckets are not truncations
        assertNone([
            // A `>` inside quotes is a character, not a redirection (round 2: SQL, awk and jq programs).
            #"echo "a > b""#,
            #"echo a >> log"#,
            #"cmd 2>&1"#,
            #"cmd >&2"#,
            #"cmd 1>&2"#,
            #"cmd >&-"#,
            #"ls > /dev/null"#,
            #"ls 2>/dev/null"#,
            #"ls &>/dev/null"#,
            #"ls > /dev/stderr"#,
            #"ls 2>/dev/stdout"#,
            #"ls >& /dev/null"#,
            #"ls &>> log"#,
            #"ls 2>> err.log"#,
            #"cmd 2>&1 | grep x"#,
            #"echo > /dev/null; ls"#,
            #"ls > /dev/null 2>&1"#,
            #"ls 2>&1 >/dev/null"#,
            #"exec 3<>/tmp/sock"#,
            #"echo hello"#,
        ])
        // a redirection is listed after the older names
        XCTAssertEqual(StagingDestructivePatterns.matches(#"echo x > a; kill -9 1"#), ["kill -9", "> file"])
        XCTAssertEqual(StagingDestructivePatterns.matches(#"rm -rf x > log"#), ["rm -rf", "> file"])
        XCTAssertEqual(StagingDestructivePatterns.matches(#"rm -rf /tmp/x 2>/dev/null"#), ["rm -rf"])
    }

    func testNewFindXargsAndPipedRmFamilyIsSeenThroughWrapping() {
        // find with delete or an exec of rm is caught
        assertAll(#"find -delete"#, [
            #"find . -name x -delete"#,
            #"find . -exec rm {} \;"#,
            #"find . -type f -execdir rm -- {} +"#,
            #"find /tmp -exec sh -c 'rm {}' \;"#,
            #"find . -ok rm {} \;"#,
            #"find . -okdir rm {} \;"#,
            #"find . -exec /bin/rm {} \;"#,
            #"find . -exec RM {} \;"#,
            #"find . -name '*.log' -mtime +7 -delete"#,
            #"/usr/bin/find . -delete"#,
            #"sudo find . -DELETE"#,
            #"FIND . -delete"#,
            #"bash -c 'find . -name x -delete'"#,
            #"echo $(find . -delete)"#,
            #"f''ind . -delete"#,
            #"\find . -delete"#,
            #"ls && find . -delete"#,
            #"find . -delete | cat"#,
            #"find${IFS}.${IFS}-delete"#,
            #"find . -name x -exec grep rm {} \;"#,
        ])
        XCTAssertEqual(StagingDestructivePatterns.matches(#"find . -exec rm -rf {} \;"#), ["rm -rf", "find -delete"])
        // find without delete or rm is not caught
        assertNone([
            #"find . -name x"#,
            #"find . -exec ls {} \;"#,
            #"find . -name delete"#,
            #"find . -print"#,
            #"find . -type f -print0 | sort -z"#,
            #"find . -name '*.log' -exec grep -l error {} +"#,
            #"echo -delete"#,
        ])
        // xargs rm and rm after a pipe are caught
        assertAll(#"xargs/piped rm"#, [
            #"xargs rm"#,
            #"xargs -0 rm -f"#,
            #"xargs -I{} rm {}"#,
            #"xargs 'rm'"#,
            #"ls | xargs rm"#,
            #"ls | sudo rm x"#,
            #"find . | while read f; do rm "$f"; done"#,
            #"echo x | sh -c 'rm y'"#,
            #"cat list | xargs -n1 rm"#,
            #"ls | /bin/rm x"#,
            #"ls | RM x"#,
            #"ls|xargs rm"#,
            #"echo x | env rm y"#,
            #"ls | \rm x"#,
            #"ls | x''args rm"#,
            #"ls | xargs${IFS}rm"#,
            #"bash -c 'ls | xargs rm'"#,
            #"(ls | xargs rm)"#,
            #"echo $(ls | xargs rm)"#,
            #"ls && ls | xargs rm"#,
            #"ls | xargs -P4 -I {} rm {}"#,
            #"ls | rm"#,
            #"find . -name x | xargs rm"#,
        ])
        XCTAssertEqual(StagingDestructivePatterns.matches(#"xargs rm -rf"#), ["rm -rf", "xargs/piped rm"])
        XCTAssertEqual(StagingDestructivePatterns.matches(#"ls | xargs rm -rf"#), ["rm -rf", "xargs/piped rm"])
        XCTAssertEqual(StagingDestructivePatterns.matches(#"ls | xargs rm -f"#), ["xargs/piped rm"])
        // rm before the pipe or after or or is not piped rm
        assertNone([
            #"rm x | grep y"#,
            #"ls || rm x"#,
            #"rm x"#,
            #"ls | grep rm-me"#,
            #"xargs echo"#,
            #"ls | xargs ls"#,
            #"rm x || ls | cat"#,
            #"echo x | tee y"#,
        ])
    }

    func testNewForceKillFamilyIsSeenThroughWrapping() {
        // every spelling of a force kill is caught
        assertAll(#"kill -9"#, [
            #"kill -s9 1"#,
            #"kill -s KILL 1"#,
            #"kill -SIGKILL 1"#,
            #"kill -KILL 1"#,
            #"kill -n9 1"#,
            #"kill -n 9 1"#,
            #"kill -sKILL 1"#,
            #"kill -ssigkill 1"#,
            #"kill --signal=KILL 1"#,
            #"kill --signal=sigkill 1"#,
            #"kill --signal=9 1"#,
            #"kill --signal 9 1"#,
            #"kill --signal KILL 1"#,
            #"kill 1 -9"#,
            #"pkill -9 x"#,
            #"pkill -f x -9"#,
            #"pkill -f x -KILL"#,
            #"killall -9 x"#,
            #"killall -s KILL x"#,
            #"/bin/kill -9 1"#,
            #"sudo kill -9 1"#,
            #"env kill -9 1"#,
            #"nohup kill -9 1"#,
            #"time kill -9 1"#,
            #"exec kill -9 1"#,
            #"command kill -9 1"#,
            #"KILL -9 1"#,
            #"bash -c 'kill -9 1'"#,
            #"echo $(kill -9 1)"#,
            #"ls && kill -9 1"#,
            #"ls; kill -9 1"#,
            #"pgrep x | xargs kill -9"#,
            #"k''ill -9 1"#,
            #"\kill -9 1"#,
            #"kill${IFS}-9${IFS}1"#,
        ])
        // gentle signals and listing signals are not force kills
        assertNone([
            #"kill 123"#,
            #"kill -15 1"#,
            #"kill -s 15 1"#,
            #"kill -s TERM 1"#,
            #"kill -HUP 1"#,
            #"kill -n 15 1"#,
            #"kill --signal=15 1"#,
            #"pkill -f x"#,
            #"pkill -TERM x"#,
            #"kill -l"#,
            #"killall x"#,
            #"kill 1; echo -9"#,
        ])
    }

    func testRedirectionGluedToAWordDoesNotHideTheVerb() {
        assertAll("kubectl delete", [
            #"kubectl delete>/dev/null ns x"#,
            #"kubectl delete</dev/null ns x"#,
            #"kubectl>/dev/null delete ns x"#,
            #"bash -c 'kubectl delete>/dev/null ns x'"#,
            #"sudo kubectl delete>/dev/null ns x"#,
        ])
        assertAll("terraform destroy", [
            #"terraform destroy>/dev/null"#,
            #"tofu destroy</dev/null"#,
        ])
        assertAll("helm uninstall", [
            #"helm uninstall</dev/null x"#,
            #"helm uninstall>/dev/null x"#,
        ])
        assertAll("aws delete/terminate", [
            #"aws s3api delete-bucket>/dev/null"#,
            #"aws s3api delete-bucket>/dev/null --bucket b"#,
        ])
        XCTAssertEqual(StagingDestructivePatterns.matches(#"kubectl delete>out.log ns x"#), ["kubectl delete", "> file"])
        // plain redirections to the bit buckets and descriptor duplications stay unlabelled
        assertNone([
            #"echo hi 2>&1"#,
            #"echo hi >&2"#,
            #"echo hi > /dev/null"#,
            #"ls>/dev/null"#,
            #"ls >/dev/null 2>&1"#,
            #"cat</dev/null"#,
            #"kubectl get pods>/dev/null"#,
            #"terraform plan>/dev/null"#,
            #"helm list</dev/null"#,
            #"aws s3api list-buckets>/dev/null"#,
        ])
    }

    func testAwsKmsScheduleKeyDeletionIsCaughtAndTheOtherKmsVerbsAreNot() {
        assertAll("aws delete/terminate", [
            #"aws kms schedule-key-deletion --key-id k"#,
            #"aws --profile prod kms schedule-key-deletion --key-id k"#,
            #"/usr/local/bin/aws kms schedule-key-deletion --key-id k"#,
            #"sudo aws kms schedule-key-deletion --key-id k"#,
            #"bash -c 'aws kms schedule-key-deletion --key-id k'"#,
            #"aws kms schedule-key-d''eletion --key-id k"#,
            #"AWS KMS SCHEDULE-KEY-DELETION --key-id k"#,
            #"aws kms schedule-key-deletion>/dev/null --key-id k"#,
        ])
        assertNone([
            #"aws kms list-keys"#,
            #"aws kms describe-key --key-id k"#,
            #"aws kms cancel-key-deletion --key-id k"#,
            #"aws kms encrypt --key-id k --plaintext x"#,
        ])
    }

    func testParallelRmIsCaughtLikeXargsRmAndOtherParallelCommandsAreNot() {
        assertAll("xargs/piped rm", [
            #"parallel rm ::: a b"#,
            #"parallel -j4 rm {} ::: a b"#,
            #"parallel 'rm -rf {}' ::: a b"#,
            #"ls | parallel rm"#,
            #"sudo parallel rm ::: a b"#,
            #"/usr/bin/parallel rm ::: a b"#,
            #"parallel /bin/rm ::: a b"#,
            #"bash -c 'parallel rm ::: a b'"#,
            #"p''arallel rm ::: a b"#,
            #"PARALLEL RM ::: a b"#,
            #"parallel rm>/dev/null ::: a b"#,
        ])
        XCTAssertEqual(StagingDestructivePatterns.matches(#"parallel 'rm -rf {}' ::: a b"#), ["rm -rf", "xargs/piped rm"])
        assertNone([
            #"parallel echo ::: a b"#,
            #"parallel gzip ::: a b"#,
            #"parallel --dry-run echo {} ::: a b"#,
            #"parallel rmdir ::: a b"#,
        ])
    }

    func testTerraformWorkspaceDeleteStateRmAndTaintAreCaughtAndReadOnlyFormsAreNot() {
        assertAll("terraform destroy", [
            #"terraform workspace delete staging"#,
            #"terraform workspace delete -force staging"#,
            #"tofu workspace delete staging"#,
            #"terraform -chdir=infra workspace delete staging"#,
            #"sudo terraform workspace delete staging"#,
            #"bash -c 'terraform workspace delete staging'"#,
            #"terraform work''space de\lete staging"#,
            #"terraform state rm aws_instance.web"#,
            #"terraform -chdir=infra state rm aws_instance.web"#,
            #"tofu state rm aws_instance.web"#,
            #"terraform state remove aws_instance.web"#,
            #"/usr/local/bin/terraform state rm aws_instance.web"#,
            #"env TF_LOG=debug terraform state rm aws_instance.web"#,
            #"TERRAFORM STATE RM aws_instance.web"#,
            #"bash -c 'terraform state rm aws_instance.web'"#,
            #"terraform state list; terraform state rm aws_instance.web"#,
            #"terraform taint aws_instance.web"#,
            #"sudo terraform taint aws_instance.web"#,
            #"tofu taint aws_instance.web"#,
            #"/usr/bin/terraform taint aws_instance.web"#,
            #"bash -c 'terraform taint aws_instance.web'"#,
            #"terraform ta''int aws_instance.web"#,
            #"terraform -chdir=infra taint aws_instance.web"#,
            #"TERRAFORM TAINT aws_instance.web"#,
        ])
        assertNone([
            #"terraform workspace list"#,
            #"terraform workspace select prod"#,
            #"terraform workspace show"#,
            #"terraform state show aws_instance.web"#,
            #"terraform state pull"#,
            #"terraform untaint aws_instance.web"#,
            #"terraform output"#,
            #"terraform state list; terraform workspace list"#,
        ])
    }

    func testSeveralNewFamiliesInOneCommandAreListedInListOrder() {
        // several families in one command are all listed in list order
        XCTAssertEqual(StagingDestructivePatterns.matches(#"kubectl delete pod web-1 && terraform destroy"#), ["kubectl delete", "terraform destroy"])
        XCTAssertEqual(StagingDestructivePatterns.matches(#"dd if=a of=b; mkfs.ext4 /dev/sdb; shred x"#), ["dd of=", "mkfs", "shred"])
        XCTAssertEqual(StagingDestructivePatterns.matches(#"ls | xargs rm -rf; find . -delete"#), ["rm -rf", "find -delete", "xargs/piped rm"])
        XCTAssertEqual(StagingDestructivePatterns.matches(#"helm uninstall web; kubectl delete ns web"#), ["kubectl delete", "helm uninstall"])
        XCTAssertEqual(StagingDestructivePatterns.matches(#"kubectl delete pod x --force; php artisan migrate:rollback"#), ["--force", "migrate:rollback", "kubectl delete"])
        // every label comes in list order, once
        let found = StagingDestructivePatterns.matches(
            #"ls | xargs rm -rf; find . -delete; echo x > a; kill -9 1; kubectl delete pod x --force; DROP TABLE y"#)
        XCTAssertEqual(found, ["rm -rf", "DROP", "--force", "kill -9", "kubectl delete", "> file", "find -delete", "xargs/piped rm"])
        XCTAssertEqual(found, found.sorted { StagingDestructivePatterns.names.firstIndex(of: $0)! < StagingDestructivePatterns.names.firstIndex(of: $1)! })

    }

    func testEveryNonASCIIScalarIsIsolatedFromTheTextBesideIt() {
        let label = StagingHazards.nonASCIILabel("\u{05D0}") ?? ""
        XCTAssertTrue(label.contains("\u{2068}\u{05D0}\u{2069} U+05D0"), label)
    }

    // MARK: History expansion (the cases of tests/fixtures/terminal_staging/hazards.json)

    func testHistoryExpansionRule() {
        let positives = ["!!", "!ssh", "!$", "!-2", "!#", "!ls -la", "echo hi !!", "^a^b", "^foo", "r", "fc -l", "history",
                         "history | grep x", "ls; r", "ls && fc", "ls || history", "ls | r 2",
                         // `fc` and `history` count as a word anywhere (S2 review): asking is the cheap side.
                         "grep history x", "rg fc"]
        for command in positives { XCTAssertTrue(StagingHazards.usesHistoryExpansion(command), command) }
        let negatives = ["[ a != b ]", "echo hi!", "echo ! x", "git status", "ls -r", "echo r", "echo !(x)",
                         "echo ^caret", "ls -la", "echo a!=b", "ls r"]
        for command in negatives { XCTAssertFalse(StagingHazards.usesHistoryExpansion(command), command) }
    }

    /// Every case in the file the daemon's tests read too: both sides must say the same.
    func testTheSharedFixtureGivesTheSameAnswerAsTheDaemon() throws {
        let cases = try StagingFixtures.hazards()
        XCTAssertGreaterThan(cases.count, 500, "hazards.json should be found")
        for entry in cases {
            let text = try XCTUnwrap(entry["text"] as? String)
            let expected = try XCTUnwrap(entry["history"] as? Bool)
            XCTAssertEqual(StagingHazards.usesHistoryExpansion(text), expected, "\(entry["name"] ?? "?"): \(text)")
        }
    }

    /// The fixture's optional `destructive` (pattern names) and `escape_quoted` (the `$'..\x..'` label) fields.
    func testTheSharedFixtureGivesTheExpectedDestructiveNamesAndEscapeQuoteLabel() throws {
        var checked = 0
        var asked = 0
        var gluedChecked = 0
        for entry in try StagingFixtures.hazards() {
            let text = try XCTUnwrap(entry["text"] as? String)
            let name = entry["name"] as? String ?? "?"
            if let names = entry["destructive"] as? [String] {
                XCTAssertEqual(StagingDestructivePatterns.matches(text), names, "\(name): \(text)")
                checked += 1
            }
            if let escaped = entry["escape_quoted"] as? Bool {
                XCTAssertEqual(StagingHazards.escapeQuotedWordLabel(text) != nil, escaped, "\(name): \(text)")
            }
            // A brace expansion glued to a word (`r{m..m}`): its own label.
            if let glued = entry["brace_glued"] as? Bool {
                XCTAssertEqual(StagingHazards.braceGluedWordLabel(text) != nil, glued, "\(name): \(text)")
                gluedChecked += 1
            }
            // Whether a production pane asks first: a destructive match, an escape-quoted word or a brace-glued word.
            if let asks = entry["asks_in_production"] as? Bool {
                XCTAssertEqual(StagingHazards.asksFirstInProduction(text), asks, "\(name): \(text)")
                asked += 1
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 100, "the fixture pins the destructive names of at least 100 rows")
        XCTAssertGreaterThanOrEqual(asked, 25, "the fixture pins whether a production pane asks for the escape-quoted and brace-glued rows")
        XCTAssertGreaterThanOrEqual(gluedChecked, 25, "the fixture pins brace_glued for at least 25 rows")
    }

    func testAnEscapeQuotedWordWithNoDestructiveMatchStillAsksInProduction() {
        for command in [#"$'\x72\x6d' -rf /var/lib/mysql"#, #"kubectl $'\x64elete' ns prod"#, #"echo $'\x72m' -rf /"#] {
            XCTAssertTrue(StagingDestructivePatterns.matches(command).isEmpty, command)
            XCTAssertTrue(StagingHazards.asksFirstInProduction(command), command)
        }
        for command in ["echo $'abc'", "ls -la", "echo hello"] {
            XCTAssertFalse(StagingHazards.asksFirstInProduction(command), command)
        }
        XCTAssertTrue(StagingHazards.asksFirstInProduction("rm -rf x"), "a destructive match still asks")
    }

    /// The two matchers split words the same way: a redirection glued to `rm` still leaves the flags a word each.
    func testRmFlagsAfterAGluedRedirectionAreSeen() {
        XCTAssertEqual(StagingDestructivePatterns.matches("rm>/dev/null -rf /var/lib/mysql"), ["rm -rf"])
        XCTAssertEqual(StagingDestructivePatterns.matches("rm</dev/null -rf /var/lib/mysql"), ["rm -rf"])
        XCTAssertEqual(StagingDestructivePatterns.matches("RM -rf /x"), ["rm -rf"])
    }

    func testEmptyExpansionsAreSeenThroughInBothForms() {
        XCTAssertEqual(StagingHazards.normalised("rm${IFS}-rf /"), "rm -rf /")
        XCTAssertEqual(StagingHazards.normalised("r$@m"), "r m")
        XCTAssertEqual(StagingHazards.normalised("r$@m", empty: ""), "rm")
        XCTAssertTrue(StagingDestructivePatterns.matches("rm${IFS}-rf /").contains("rm -rf"))
        XCTAssertTrue(StagingDestructivePatterns.matches("r$()m -rf /").contains("rm -rf"))
        XCTAssertTrue(StagingHazards.usesHistoryExpansion("X=1 r"))
        XCTAssertTrue(StagingHazards.usesHistoryExpansion("nice -n 5 r"))
        XCTAssertTrue(StagingHazards.usesHistoryExpansion("- r"))
    }

    // MARK: Non-ASCII

    func testALookAlikeLetterIsNamedWithItsCodePoint() {
        XCTAssertEqual(StagingHazards.nonASCIILabel("echo \u{0430}"),
                       "\u{26A0} Contains non-ASCII: \u{2068}\u{0430}\u{2069} U+0430 CYRILLIC SMALL LETTER A")
        XCTAssertNil(StagingHazards.nonASCIILabel("echo hello"))
    }

    func testAtMostThreeDistinctScalarsAreNamedThenAndNMore() {
        let label = StagingHazards.nonASCIILabel("\u{0430}\u{0430}\u{0431}\u{0432}\u{0433}\u{0434}") ?? ""
        XCTAssertTrue(label.contains("U+0430"), label)
        XCTAssertTrue(label.contains("U+0431"), label)
        XCTAssertTrue(label.contains("U+0432"), label)
        XCTAssertFalse(label.contains("U+0433"), label)
        XCTAssertTrue(label.hasSuffix("and 2 more"), label)
        XCTAssertEqual(label.components(separatedBy: "U+0430").count - 1, 1, "a repeated scalar is named once")
    }

    /// The shared fixture the daemon's tests read too: every case's `history` flag is what the app computes.
    func testTheSharedHazardsFixtureAgreesWithTheAppsHistoryRule() throws {
        let data = try StagingFixtures.fixtureData("hazards.json")
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 500, "hazards.json should be found")
        for entry in cases {
            let name = entry["name"] as? String ?? "?"
            let text = try XCTUnwrap(entry["text"] as? String, name)
            let expected = try XCTUnwrap(entry["history"] as? Bool, name)
            XCTAssertEqual(StagingHazards.usesHistoryExpansion(text), expected, "\(name): \(text)")
        }
    }
}

// MARK: - Round 2: quoted openers, brace groups glued to a word, `>` in quotes, command position, the read-only corpus

extension StagingHazardsTests {

    private static let escapeQuotedText = "\u{26A0} Contains an escape-quoted word ($'...' with a backslash): what runs may differ from what you see."
    private static let braceGluedText = "\u{26A0} Contains a brace expansion glued to a word ({a,b} or {1..3}): what runs may differ from what you see."
    private static let asksFirstSuffix = " Insert asks first."

    private func wordSet(_ view: String) -> Set<String> {
        Set(view.split(whereSeparator: { $0.isWhitespace }).map(String.init))
    }

    /// The first `;`, `|`, `&` separated segment of `view` that has `word` as one of its words.
    private func segment(of view: String, withWord word: String) -> String? {
        StagingHazards.segments(of: view).first { wordSet($0).contains(word) }
    }

    // MARK: Quoted and escaped substitution openers, and a quote-aware closer
    //
    // The words view puts the inner words of `$(...)`, a backtick pair and `<(...)` in the segment after a `_`
    // placeholder, with `;`, `|` and `&` inside turned into spaces, and its closer search skips a quoted or
    // backslash-escaped `)`, `}` or backtick. The daemon's `destructive.rs` tests hold the same cases.

    func testAQuotedOrEscapedOpenerDoesNotHideTheWordsAShellRunsAfterIt() {
        let cases: [(command: String, names: [String])] = [
            (#"rm '$(' '-rf' /x ')'"#, ["rm -rf"]),
            (#"rm '`' '-rf' /x '`'"#, ["rm -rf"]),
            (#"rm '<(' '-rf' /x ')'"#, ["rm -rf"]),
            (#"rm a\` '-rf' /x b\`"#, ["rm -rf"]),
            (#"kubectl -n '$(' 'delete' ns prod ')'"#, ["kubectl delete"]),
            (#"kubectl '`' 'delete' ns prod '`'"#, ["kubectl delete"]),
            (#"kubectl $(echo "(") 'delete' ns prod "x)""#, ["kubectl delete"]),
            (#"terraform '$(' 'destroy' -auto-approve ')'"#, ["terraform destroy"]),
            (#"helm '$(' 'uninstall' rel ')'"#, ["helm uninstall"]),
            (#"aws '$(' ec2 'terminate-instances' --instance-ids i-1 ')'"#, ["aws delete/terminate"]),
            (#"aws '`' ec2 'terminate-instances' --instance-ids i-1 '`'"#, ["aws delete/terminate"]),
            (#"pkill '$(' '-9' x ')'"#, ["kill -9"]),
            (#"kill '$(' '-9' 1 ')'"#, ["kill -9"]),
        ]
        for (command, names) in cases {
            XCTAssertEqual(StagingDestructivePatterns.matches(command), names, command)
        }
    }

    func testACloserThatSkipsAQuotedOrEscapedParenOrBacktickKeepsTheVerbAfterItsProgram() {
        // The segment must not be split at the `;` inside the substitution: only a quote-aware closer sees that the
        // `)` in the string does not end it.
        let cases: [(command: String, names: [String])] = [
            (#"kubectl $(echo ")"; echo x) delete ns prod"#, ["kubectl delete"]),
            (#"kubectl $(echo ')'; echo x) delete ns prod"#, ["kubectl delete"]),
            (#"kubectl `echo \`;echo x` delete ns prod"#, ["kubectl delete"]),
            (#"terraform $(echo ")"; echo x) destroy"#, ["terraform destroy"]),
            (#"kubectl ${X:-"}"; echo y} delete ns prod"#, ["kubectl delete"]),
        ]
        for (command, names) in cases {
            XCTAssertEqual(StagingDestructivePatterns.matches(command), names, command)
        }
    }

    func testSubstitutionsThatHideNothingStayUnlabelled() {
        for command in [#"echo '$(' hello ')'"#, "kubectl get pods -l app=$(cat app.txt)", "ls $(echo a; echo b)",
                        "echo $(date) && ls ${HOME}/x"] {
            XCTAssertEqual(StagingDestructivePatterns.matches(command), [], command)
        }
    }

    func testTheWordsViewEmitsTheInnerWordsOfSubstitutionsAfterThePlaceholder() {
        let cases: [(text: String, words: [String])] = [
            ("echo $(rm -rf /x)", ["echo", "_", "rm", "-rf", "/x"]),
            ("echo `kubectl delete ns x`", ["echo", "_", "kubectl", "delete", "ns"]),
            ("diff <(sort a.txt) <(cat b.txt)", ["diff", "_", "sort", "a.txt", "cat", "b.txt"]),
            ("kubectl ${X:-delete} ns prod", ["kubectl", "_", "delete", "ns", "prod"]),
        ]
        for (text, words) in cases {
            let view = StagingHazards.normalisedWords(text)
            for word in words {
                XCTAssertTrue(wordSet(view).contains(word), "\(word) should be a word of \(view) (from \(text))")
            }
        }
    }

    func testSeparatorsInsideASubstitutionDoNotSplitTheOuterSegment() {
        for text in ["ls $(echo a; echo b | wc -l && echo c) ; ls",
                     "ls `echo a; echo b | wc -l && echo c` ; ls",
                     "ls <(echo a; echo b | wc -l && echo c) ; ls"] {
            let view = StagingHazards.normalisedWords(text)
            XCTAssertEqual(view.filter { $0 == ";" }.count, 1, "only the outer `;` is left in \(view) (from \(text))")
            XCTAssertFalse(view.contains("|") || view.contains("&"), "no `|` or `&` is left in \(view) (from \(text))")
            for word in ["echo", "wc", "a", "b"] {
                XCTAssertTrue(wordSet(view).contains(word), "\(word) should be a word of \(view)")
            }
        }
    }

    func testTheWordsViewCloserSkipsAQuotedOrEscapedParenAndAnEscapedBacktick() {
        for text in [#"kubectl $(echo ")"; echo x) delete ns prod"#,
                     #"kubectl $(echo ')'; echo x) delete ns prod"#,
                     #"kubectl $(echo \); echo x) delete ns prod"#,
                     #"kubectl `echo \`;echo x` delete ns prod"#] {
            let view = StagingHazards.normalisedWords(text)
            XCTAssertFalse(view.contains(";"), "the `;` inside the substitution must not survive in \(view) (from \(text))")
            let kubectl = segment(of: view, withWord: "kubectl")
            XCTAssertNotNil(kubectl, "a segment with kubectl in \(view)")
            XCTAssertTrue(wordSet(kubectl ?? "").contains("delete"), "`delete` must stay in kubectl's segment: \(view) (from \(text))")
        }
    }

    func testTheWordsViewCloserSkipsAQuotedBrace() {
        let view = StagingHazards.normalisedWords(#"kubectl ${X:-"}"; echo y} delete ns prod"#)
        let kubectl = segment(of: view, withWord: "kubectl")
        XCTAssertNotNil(kubectl, "a segment with kubectl in \(view)")
        XCTAssertTrue(wordSet(kubectl ?? "").contains("delete"), "`delete` must stay in kubectl's segment: \(view)")
    }

    func testAnUnbalancedOpenerIsDroppedAndWhatFollowsStaysVisible() {
        let view = StagingHazards.normalisedWords("kubectl --context $(echo x delete ns y")
        XCTAssertTrue(wordSet(segment(of: view, withWord: "kubectl") ?? "").contains("delete"), view)
    }

    // MARK: Brace groups glued to a word
    //
    // `r{m..m}` is `rm` to a shell and nothing a text rule can follow: it fails toward the sheet (a production pane
    // asks first) instead of expanding. A group alone as a word (`ls {a,b}`), a quoted or escaped one and `${...}`
    // are not it. `file{1,2}.txt` and `cp f{,.bak}` ARE glued, so they ask in production too: the documented cost
    // of failing toward confirmation.

    private static let bracesGlued: [String] = [
        "r{m..m} -rf /x", "{r..r}m -rf /x", "{r,}m -rf /x", "r{m,} -rf /x", "kubectl d{e..e}lete ns prod",
        "terraform d{e..e}stroy -auto-approve", "aws s3 r{m..m} s3://b --recursive", "kill -{9..9} 1",
        "{s,}hred -u old.log", "redis-cli flush{a..a}ll", "rm -{r,f} /x", "cp file{,.bak}", "ls file{1,2}.txt",
        "echo a{b,c}d", "echo x{1..3}",
        // glued after the closing brace by something that is not a separator or a redirection
        "ls {a,b}/c",
        // a quote counts as glue
        #"echo "x"{a,b}"#, "echo 'x'{a,b}",
        // the quoted argument of a command wrapper is analysed as live code
        "bash -c 'ls file{1,2}.txt'", "ssh prod-host 'ls file{1,2}.txt'", #"sh -c "cp f{,.bak}""#,
    ]

    private static let bracesNotGlued: [String] = [
        // a group alone as a word
        "ls {a,b}", "echo {a,b} x", "ls {1..3}", "{rm,-rf,/x}", "kubectl {delete,} ns prod",
        // glued only to a separator, a redirection or a parenthesis
        "ls {a,b};ls", "ls {a,b}|wc -l", "cat <{a,b}", "echo ({a,b})",
        // a parameter expansion
        "echo ${HOME}", "echo ${X:-a,b}", "echo ${X:-1..3}",
        // not a brace expansion: no comma and no `..` in the body
        "xargs -I{} rm {}", #"find . -exec rm {} \;"#, "echo a{b}c", "echo x{}y",
        // quoted (not a command wrapper's argument) or escaped
        "jq '{a,b}' f.json", "kubectl get pods -o jsonpath='{.items[*].metadata.name}'",
        "aws ec2 describe-instances --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name}'",
        #"echo \{a,b\}x"#, "echo 'r{m,}'", #"echo "{a,b}x""#, "echo hello",
    ]

    func testABraceExpansionGluedToAWordHasItsLabelAndAsksFirstInProduction() {
        for command in Self.bracesGlued {
            XCTAssertEqual(StagingHazards.braceGluedWordLabel(command), Self.braceGluedText, command)
            XCTAssertEqual(StagingHazards.braceGluedWordLabel(command, production: false), Self.braceGluedText, command)
            XCTAssertEqual(StagingHazards.braceGluedWordLabel(command, production: true), Self.braceGluedText + Self.asksFirstSuffix, command)
            XCTAssertTrue(StagingHazards.asksFirstInProduction(command), command)
        }
    }

    func testABraceGroupThatIsNotGluedNotAnExpansionOrNotLiveHasNoLabel() {
        for command in Self.bracesNotGlued {
            XCTAssertNil(StagingHazards.braceGluedWordLabel(command), command)
            XCTAssertNil(StagingHazards.braceGluedWordLabel(command, production: true), command)
        }
    }

    func testTheEscapeQuotedLabelSaysInsertAsksFirstOnlyInProduction() {
        let command = #"echo $'\x72m' -rf /"#
        XCTAssertEqual(StagingHazards.escapeQuotedWordLabel(command), Self.escapeQuotedText)
        XCTAssertEqual(StagingHazards.escapeQuotedWordLabel(command, production: false), Self.escapeQuotedText)
        XCTAssertEqual(StagingHazards.escapeQuotedWordLabel(command, production: true), Self.escapeQuotedText + Self.asksFirstSuffix)
        XCTAssertNil(StagingHazards.escapeQuotedWordLabel("echo $'abc'", production: true))
        XCTAssertNil(StagingHazards.escapeQuotedWordLabel("echo hello", production: false))
    }

    func testAProductionPaneAsksForADestructiveMatchAnEscapeQuotedWordOrABraceGluedWord() {
        // Each of the three on its own, with no destructive match for the last two.
        XCTAssertTrue(StagingHazards.asksFirstInProduction("rm -rf x"))
        XCTAssertEqual(StagingDestructivePatterns.matches(#"echo $'\x72m' -rf /"#), [])
        XCTAssertTrue(StagingHazards.asksFirstInProduction(#"echo $'\x72m' -rf /"#))
        XCTAssertEqual(StagingDestructivePatterns.matches("r{m..m} -rf /x"), [])
        XCTAssertTrue(StagingHazards.asksFirstInProduction("r{m..m} -rf /x"))
        XCTAssertEqual(StagingDestructivePatterns.matches("ls file{1,2}.txt"), [])
        XCTAssertTrue(StagingHazards.asksFirstInProduction("ls file{1,2}.txt"))
        // and none of them
        for command in ["ls -la", "echo hello", "echo ${HOME}", "ls {a,b}", "echo 'r{m,}'", "jq '{a,b}' f.json",
                        "kubectl get pods -o jsonpath='{.items[*].metadata.name}'",
                        "mysql -e 'SELECT id FROM jobs WHERE created_at > NOW() - INTERVAL 1 DAY'", "last reboot | head"] {
            XCTAssertFalse(StagingHazards.asksFirstInProduction(command), command)
        }
    }

    // MARK: pulumi and an aws ecs service scaled to a signed zero

    func testPulumiDownStackRmAndStateDeleteAreTerraformDestroysAndTheReadOnlyVerbsAreNot() {
        for command in ["pulumi down", "pulumi down --yes", "pulumi stack rm", "pulumi stack rm --yes", "pulumi state delete",
                        "pulumi destroy --yes"] {
            XCTAssertEqual(StagingDestructivePatterns.matches(command), ["terraform destroy"], command)
        }
        for command in ["pulumi up", "pulumi stack ls", "pulumi preview", "pulumi stack output"] {
            XCTAssertEqual(StagingDestructivePatterns.matches(command), [], command)
        }
    }

    func testAnEcsServiceScaledToASignedZeroIsLabelledAndAPositiveCountIsNot() {
        for count in ["--desired-count +0", "--desired-count -0", "--desired-count=+0", "--desired-count=-0"] {
            let command = "aws ecs update-service --cluster c --service s \(count)"
            XCTAssertEqual(StagingDestructivePatterns.matches(command), ["aws delete/terminate"], command)
        }
        for count in ["--desired-count 2", "--desired-count +2", "--desired-count=+2", "--desired-count 10"] {
            let command = "aws ecs update-service --cluster c --service s \(count)"
            XCTAssertEqual(StagingDestructivePatterns.matches(command), [], command)
        }
    }

    // MARK: A `>` inside quotes is not a redirection
    //
    // Except in the quoted argument of a command wrapper (a shell, `eval`, `ssh`, `mosh`, `parallel`, `watch`, `su`,
    // `script`, `flock`, `runuser`): that string runs as code, with its own quotes tracked again. A `>` in a `$(...)`
    // or backticks inside a double-quoted string is live too, and an unterminated quote counts as unquoted.

    func testAGreaterThanInsideQuotesIsNotATruncatingRedirection() {
        for command in ["mysql -e 'SELECT id FROM jobs WHERE created_at > NOW() - INTERVAL 1 DAY'",
                        #"mysql -e "SELECT id FROM jobs WHERE attempts >= 3""#,
                        #"php artisan tinker --execute='App\Models\Job::where("created_at", ">", now()->subDay())->count()'"#,
                        "jq '.[] | select(.requests > 100)' stats.json",
                        "awk '$9 >= 500 {print $7}' access.log",
                        "echo x '>' y",
                        // a quote nested inside a wrapper's argument is a quote again
                        #"bash -c "mysql -e 'select 1 > 0'""#,
                        #"ssh h 'mysql -e "select 1 > 0"'"#] {
            XCTAssertEqual(StagingDestructivePatterns.matches(command), [], command)
        }
    }

    func testAGreaterThanInACommandWrappersQuotedArgumentOrOutsideQuotesIsStillATruncation() {
        for command in ["bash -c 'echo x > f'", #"sh -c "cat y > f""#, "ssh h 'echo x > f'", "eval 'echo x > f'",
                        "awk $3 > 80 f", "parallel 'echo {} > f' ::: a b", "xargs -I{} sh -c 'echo {} > out.txt'",
                        "watch -n 5 'date > f'", "su deploy -c 'echo x > f'", "echo x > 'f'",
                        // `$(...)` and backticks inside a double-quoted string run
                        #"echo "$(date > f)""#, #"echo "`date > f`""#,
                        // an unterminated quote counts as unquoted
                        "echo 'a > b"] {
            XCTAssertTrue(StagingDestructivePatterns.matches(command).contains("> file"), command)
        }
        XCTAssertEqual(StagingDestructivePatterns.matches("xargs -I{} sh -c 'echo {} > out.txt'"), ["> file"])
    }

    // MARK: Stop and shutdown only where a command can start
    //
    // `shutdown`, `reboot`, `halt`, `poweroff`, `systemctl ... stop|disable|mask` and `service ... stop` count in
    // COMMAND POSITION of a segment: first, after prefix words (an assignment, `sudo`, `env`, `nice` and its number,
    // `timeout` and its duration, `nohup`, `exec`, `command`, `time`, an option and the argument of one that takes
    // one), or after a wrapper word earlier in the segment (a shell, `eval`, `ssh`, `xargs`, `parallel`, `watch`,
    // `su`, `find -exec`, `kubectl|docker exec|run`, ...). Merely naming one (`last reboot`, `grep shutdown`) does not.

    func testAShutdownWordThatIsOnlyAnArgumentDoesNotStopAnything() {
        for command in ["last reboot | head", "grep -i shutdown /var/log/syslog", "journalctl -b | grep -i poweroff",
                        "echo reboot", "echo systemctl stop nginx", "man shutdown",
                        "grep -rn 'service nginx stop' /etc/init.d", "systemctl status nginx", "service nginx status",
                        "systemctl restart nginx", "systemctl is-active nginx"] {
            XCTAssertEqual(StagingDestructivePatterns.matches(command), [], command)
        }
    }

    func testAShutdownProgramInCommandPositionIsLabelledWhereverThePrefixWordsPutIt() {
        for command in ["shutdown -h now", "sudo reboot", "/sbin/shutdown -h now", "FOO=1 reboot", "timeout 5 halt",
                        "timeout 5s halt", "sudo -u root systemctl stop nginx", "nice -n 5 poweroff", "ssh prod-host reboot",
                        "bash -c 'sudo reboot'", "xargs -n1 systemctl disable", "service nginx stop", "sudo service nginx stop",
                        "systemctl --user mask foo", "sudo systemctl disable --now nginx", "ls; reboot",
                        "kubectl exec p -- reboot", "halt", "poweroff"] {
            XCTAssertEqual(StagingDestructivePatterns.matches(command), ["stop/shutdown"], command)
        }
    }

    // MARK: The read-only corpus
    //
    // Sixty realistic read-only production commands. None of them may ask in a production pane and none may carry a
    // destructive label. A new rule that trips one of them is a false positive: fix the rule, not the row. A row
    // marked `"expect": "sheet"` (with a `reason`) is the one allowed exception.

    func testTheReadOnlyCorpusNeverAsksInProductionAndNeverCarriesALabel() throws {
        let data = try StagingFixtures.fixtureData("read_only_corpus.json")
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]], "read_only_corpus.json should be an array of objects")
        XCTAssertEqual(rows.count, 60, "the corpus is exactly 60 commands")
        let texts = rows.compactMap { $0["text"] as? String }
        XCTAssertEqual(texts.count, 60)
        XCTAssertEqual(Set(texts).count, 60, "the commands are unique")
        XCTAssertEqual(Set(rows.compactMap { $0["name"] as? String }).count, 60, "the names are unique")
        for row in rows {
            XCTAssertTrue(["ok", "sheet"].contains(row["expect"] as? String ?? ""), "\(row["name"] ?? "?"): expect is ok or sheet")
        }
        let sheet = rows.filter { ($0["expect"] as? String) == "sheet" }.compactMap { $0["text"] as? String }
        XCTAssertLessThanOrEqual(sheet.count, 1, "at most one exception, got \(sheet)")
        let asking = texts.filter { StagingHazards.asksFirstInProduction($0) }
        XCTAssertEqual(asking, sheet, "exactly the rows marked sheet ask in production; any other command here is a false positive")
        for row in rows where (row["expect"] as? String) == "ok" {
            let text = try XCTUnwrap(row["text"] as? String)
            XCTAssertEqual(StagingDestructivePatterns.matches(text), [], "\(row["name"] ?? "?"): \(text) must carry no label")
        }
    }
}
