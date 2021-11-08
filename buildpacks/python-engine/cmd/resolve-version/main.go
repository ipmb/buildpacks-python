package main

import (
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"io/ioutil"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"time"

	"github.com/jmorrell/semver"
)

type result struct {
	Name                  string     `xml:"Name"`
	KeyCount              int        `xml:"KeyCount"`
	MaxKeys               int        `xml:"MaxKeys"`
	IsTruncated           bool       `xml:"IsTruncated"`
	ContinuationToken     string     `xml:"ContinuationToken"`
	NextContinuationToken string     `xml:"NextContinuationToken"`
	Prefix                string     `xml:"Prefix"`
	Contents              []s3Object `xml:"Contents"`
}

type s3Object struct {
	Key          string    `xml:"Key"`
	LastModified time.Time `xml:"LastModified"`
	ETag         string    `xml:"ETag"`
	Size         int       `xml:"Size"`
	StorageClass string    `xml:"StorageClass"`
}

type pyPIRelease struct {
	URL            string `json:url`
	Yanked         bool   `json:yanked`
	PackageType    string `json:packagetype`
	RequiresPython string `json:requires_python`
}

type pyPIResponse struct {
	Releases map[string][]pyPIRelease `json:"releases"`
}

type pyPIObject struct {
	Version string
	URL     string
}

type release struct {
	binary   string
	stage    string
	platform string
	url      string
	version  semver.Version
}

type matchResult struct {
	versionRequirement string
	release            release
	matched            bool
}

func convertPipVerToSemver(version string) string {
	pre := ""
	if strings.Contains(version, "b") {
		split := strings.SplitN(version, "b", 2)
		version = split[0]
		pre = "b" + split[1]
	}
	if len(strings.Split(version, ".")) == 2 {
		return fmt.Sprintf("%s.0", version)
	}
	if pre != "" {
		version = fmt.Sprintf("%s-%s", version, pre)
	}
	return version
}

func main() {
	if len(os.Args) < 3 {
		fmt.Println("rv BINARY VERSION_REQUIREMENT")
		os.Exit(0)
	}

	binary := os.Args[1]
	versionRequirement := os.Args[2]
	resolve(binary, versionRequirement)
}

func resolve(binary string, versionRequirement string) {
	// special-case this string since nodebin does as well and some users use it
	if versionRequirement == "latest" {
		versionRequirement = "*"
	}

	if binary == "python" {
		objects, err := listS3Objects("heroku-buildpack-python", "us-east-1", "heroku-20/runtimes/")
		if err != nil {
			fmt.Println(err)
			os.Exit(1)
		}
		result, err := resolvePython(objects, getPlatform(), versionRequirement)
		if err != nil {
			fmt.Println(err)
			os.Exit(1)
		}
		if result.matched {
			fmt.Printf("%s %s\n", result.release.version.String(), result.release.url)
		} else {
			fmt.Println("No result")
			os.Exit(1)
		}
	} else if binary == "pip" {
		releases, err := listPyPIObjects("pip")
		if err != nil {
			fmt.Println(err)
			os.Exit(1)
		}
		// In Python it's customary to use a * instead of an x for a wildcard
		result, pyPIVersion, err := resolvePip(releases, strings.ReplaceAll(versionRequirement, "*", "x"))
		if err != nil {
			fmt.Println(err)
			os.Exit(1)
		}
		if result.matched {
			fmt.Printf("%s %s\n", *pyPIVersion, result.release.url)
		} else {
			fmt.Println("No result")
			os.Exit(1)
		}
	}
}

func getPlatform() string {
	if runtime.GOOS == "darwin" {
		return "darwin-x64"
	}
	return "linux-x64"
}

func resolvePython(objects []s3Object, platform string, versionRequirement string) (matchResult, error) {
	releases := []release{}
	staging := []release{}

	for _, obj := range objects {
		release, err := parseObject(obj.Key)
		if err != nil {
			continue
		}

		// ignore any releases that are not for the given platform
		// if release.platform != platform {
		// 	continue
		// }

		// if release.stage == "release" {
		releases = append(releases, release)
		// } else {
		// 	staging = append(staging, release)
		// }
	}

	result, err := matchReleaseSemver(releases, versionRequirement)
	if err != nil {
		return matchResult{}, err
	}

	// In order to accomodate integrated testing of staged Node binaries before they are
	// released broadly, there is a special case where:
	//
	// - if there is no match to a Node binary AND
	// - an exact version of a binary in `node/staging` is present
	//
	// the staging binary is used
	if result.matched == false {
		stagingResult := matchReleaseExact(staging, versionRequirement)
		if stagingResult.matched {
			return stagingResult, nil
		}
	}

	return result, nil
}

func resolvePip(pyPIReleases map[string][]pyPIRelease, versionRequirement string) (matchResult, *string, error) {
	releases := []release{}
	semVerTOPipVer := map[string]string{}
	// pip doesn't strictly follow SemVer, but it's close enough that
	// we can convert it to someething the semver package can parse
	for version, obj := range pyPIReleases {
		semvered := convertPipVerToSemver(version)
		semVerTOPipVer[semvered] = version
		sver, err := semver.Make(semvered)
		if err != nil {
			fmt.Printf("unable to convert pip version %s to SemVer", version)
			continue
		}
		for _, r := range obj {
			if !r.Yanked && r.PackageType == "bdist_wheel" {
				// if we have an exact match, use that
				// because they can't all pass into semver
				if version == versionRequirement {
					return matchResult{
						versionRequirement: versionRequirement,
						release:            release{url: r.URL, version: sver},
						matched:            true,
					}, &version, nil
				}
				releases = append(releases, release{
					url:     r.URL,
					version: sver,
				})
			}
		}
	}
	match, err := matchReleaseSemver(releases, versionRequirement)
	if err != nil {
		return match, nil, err
	}
	// if there's a match, pass back the real pip version in addition to semver
	if match.matched {
		realVersion := semVerTOPipVer[match.release.version.String()]
		return match, &realVersion, nil
	}
	return match, nil, nil
}

func matchReleaseSemver(releases []release, versionRequirement string) (matchResult, error) {
	constraints, err := semver.ParseRange(versionRequirement)
	if err != nil {
		return matchResult{}, err
	}

	filtered := []release{}
	for _, release := range releases {
		if constraints(release.version) {
			filtered = append(filtered, release)
		}
	}

	versions := make([]semver.Version, len(filtered))
	for i, rel := range filtered {
		versions[i] = rel.version
	}

	coll := semver.Versions(versions)
	sort.Sort(coll)

	if len(coll) == 0 {
		return matchResult{
			versionRequirement: versionRequirement,
			release:            release{},
			matched:            false,
		}, nil
	}

	resolvedVersion := coll[len(coll)-1]

	for _, rel := range filtered {
		if rel.version.Equals(resolvedVersion) {
			return matchResult{
				versionRequirement: versionRequirement,
				release:            rel,
				matched:            true,
			}, nil
		}
	}
	return matchResult{}, errors.New("Unknown error")
}

func matchReleaseExact(releases []release, version string) matchResult {
	for _, release := range releases {
		if release.version.String() == version {
			return matchResult{
				versionRequirement: version,
				release:            release,
				matched:            true,
			}
		}
	}
	return matchResult{
		versionRequirement: version,
		release:            release{},
		matched:            false,
	}
}

// Parses an S3 key into a struct of information about that release
// Example input: node/release/linux-x64/node-v6.2.2-linux-x64.tar.gz
func parseObject(key string) (release, error) {
	pythonRegex := regexp.MustCompile(`heroku-20\/runtimes\/python-([0-9]+\.[0-9]+\.[0-9]+)\.tar\.gz`)
	yarnRegex := regexp.MustCompile("yarn\\/([^\\/]+)\\/yarn-v([0-9]+\\.[0-9]+\\.[0-9]+)\\.tar\\.gz")

	if pythonRegex.MatchString(key) {
		match := pythonRegex.FindStringSubmatch(key)
		version, err := semver.Make(match[1])
		if err != nil {
			return release{}, fmt.Errorf("Failed to parse version as semver:%s\n%s", match[3], err.Error())
		}
		return release{
			binary: "python",
			//stage:    match[1],
			//platform: match[2],
			version: version,
			url:     fmt.Sprintf("https://s3.amazonaws.com/%s/%s", "heroku-buildpack-python", match[0]),
		}, nil
	}

	if yarnRegex.MatchString(key) {
		match := yarnRegex.FindStringSubmatch(key)
		version, err := semver.Make(match[2])
		if err != nil {
			return release{}, errors.New("Failed to parse version as semver")
		}
		return release{
			binary:   "yarn",
			stage:    match[1],
			platform: "",
			url:      fmt.Sprintf("https://s3.amazonaws.com/heroku-nodebin/yarn/release/yarn-v%s.tar.gz", version),
			version:  version,
		}, nil
	}

	return release{}, fmt.Errorf("Failed to parse key: %s", key)
}

// Wrapper around the S3 API for listing objects
// This maps directly to the API and parses the XML response but will not handle
// paging and offsets automaticaly
func fetchS3Result(bucketName string, region string, options map[string]string) (result, error) {
	var result result
	v := url.Values{}
	v.Set("list-type", "2")
	v.Set("max-keys", "2000")
	for key, val := range options {
		v.Set(key, val)
	}
	url := fmt.Sprintf("https://%s.s3.%s.amazonaws.com?%s", bucketName, region, v.Encode())
	resp, err := http.Get(url)
	if err != nil {
		return result, err
	}

	if resp.StatusCode >= 300 {
		return result, fmt.Errorf("Unexpected status code: %d for listing S3 bucket: %s", resp.StatusCode, bucketName)
	}

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return result, err
	}

	return result, xml.Unmarshal(body, &result)
}

// Query the S3 API for a list of all the objects in an S3 bucket with a
// given prefix. This will handle the inherent 1000 item limit and paging
// for you
func listS3Objects(bucketName string, region string, prefix string) ([]s3Object, error) {
	var out = []s3Object{}
	var options = map[string]string{"prefix": prefix}

	for {
		result, err := fetchS3Result(bucketName, region, options)
		if err != nil {
			return nil, err
		}

		out = append(out, result.Contents...)
		if !result.IsTruncated {
			break
		}

		options["continuation-token"] = result.NextContinuationToken
	}

	return out, nil
}

// Query the PyPI API for a list of all the releases for a project
func listPyPIObjects(project string) (map[string][]pyPIRelease, error) {
	var out = pyPIResponse{}
	url := fmt.Sprintf("https://pypi.org/pypi/%s/json", project)
	resp, err := http.Get(url)
	if err != nil {
		return nil, err
	}
	d, err := ioutil.ReadAll(resp.Body)
	if err = json.Unmarshal(d, &out); err != nil {
		return nil, err
	}

	return out.Releases, nil
}
