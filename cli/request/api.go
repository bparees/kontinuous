package api

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"

	"encoding/base64"
	"encoding/json"
	"io/ioutil"
	"net/http"

	scm "github.com/AcalephStorage/kontinuous/scm"
	"github.com/Sirupsen/logrus"
	"github.com/dgrijalva/jwt-go"
	"github.com/spf13/viper"
)

type (
	Config struct {
		Host   string
		Token  string
		Secret string
	}

	Error struct {
		Code    int    `json:"Code"`
		Message string `json:"Message"`
	}

	PipelineData struct {
		ID     string   `json:"id"`
		Owner  string   `json:"owner"`
		Repo   string   `json:"repo"`
		Events []string `json:"events"`
		Login  string   `json:"login"`
	}

	RepoData struct {
		Owner string `json:"owner"`
		Name  string `json:"name"`
	}

	BuildData struct {
		Number   int          `json:"number"`
		Status   string       `json:"status"`
		Created  int64        `json:"created"`
		Finished int64        `json:"finished"`
		Event    string       `json:"event"`
		Author   string       `json:"author"`
		Commit   string       `json:"commit"`
		Stages   []*StageData `json:"stages"`
	}

	StageData struct {
		Index     int    `json:"index"`
		Name      string `json:"name"`
		Type      string `json:"type"`
		Status    string `json:"status"`
		Started   int64  `json:"start-time"`
		Finished  int64  `json:"end-time"`
		JobName   string `json:"job_name"`
		Namespace string `json:"namespace"`
		PodName   string `json:"pod_name"`
	}

	GithubUser struct {
		ID int `json:"id"`
	}
)

func GetConfigFromFile(file string) (*Config, error) {
	_, err := os.Stat(file)
	if err != nil {
		logrus.WithError(err).Errorln("Unable to read config file")
		return nil, err
	}

	v := viper.New()
	v.SetConfigType("yaml")
	v.SetConfigFile(file)
	v.ReadInConfig()

	config := &Config{}
	err = v.Unmarshal(&config)
	if err != nil {
		logrus.WithError(err).Errorln("Unable to read config file")
		return nil, err
	}

	err = config.validate()
	if err != nil {
		logrus.WithError(err).Errorln("Invalid config file")
		return nil, err
	}

	return config, nil
}

func (c *Config) GetPipelines(client *http.Client, pipelineName string) ([]*PipelineData, error) {
	body, err := c.sendAPIRequest(client, "GET", "/api/v1/pipelines", nil)
	if err != nil {
		return nil, err
	}
	list := []*PipelineData{}
	err = json.Unmarshal(body, &list)
	if err != nil {
		return nil, err
	}
	if len(pipelineName) > 0 {
		for _, p := range list {
			pname := strings.Join([]string{p.Owner, p.Repo}, "/")
			if pname == pipelineName {
				return []*PipelineData{p}, nil
			}
		}
		return nil, fmt.Errorf("Pipeline for `%s` not found", pipelineName)
	}
	return list, nil
}

func (c *Config) GetRepos(client *http.Client) ([]*RepoData, error) {
	body, err := c.sendAPIRequest(client, "GET", "/api/v1/repositories", nil)
	if err != nil {
		return nil, err
	}
	list := []*RepoData{}
	err = json.Unmarshal(body, &list)
	if err != nil {
		return nil, err
	}

	return list, nil
}

func (c *Config) GetBuilds(client *http.Client, owner, repo string) ([]*BuildData, error) {
	endpoint := fmt.Sprintf("/api/v1/pipelines/%s/%s/builds", owner, repo)
	body, err := c.sendAPIRequest(client, "GET", endpoint, nil)
	if err != nil {
		return nil, err
	}
	list := []*BuildData{}
	err = json.Unmarshal(body, &list)
	if err != nil {
		return nil, err
	}
	return list, nil
}

func (c *Config) GetStages(client *http.Client, owner, repo string, buildNumber int) ([]*StageData, error) {
	if buildNumber == 0 {
		builds, err := c.GetBuilds(client, owner, repo)
		if err != nil {
			return nil, err
		}
		if len(builds) == 0 {
			return []*StageData{}, nil
		}
		lastBuild := builds[len(builds)-1]
		buildNumber = lastBuild.Number
	}

	endpoint := fmt.Sprintf("/api/v1/pipelines/%s/%s/builds/%d/stages", owner, repo, buildNumber)
	body, err := c.sendAPIRequest(client, "GET", endpoint, nil)
	if err != nil {
		return nil, err
	}
	list := []*StageData{}
	err = json.Unmarshal(body, &list)
	if err != nil {
		return nil, err
	}

	return list, nil
}

func (c *Config) GetUser(client *http.Client) (*GithubUser, error) {
	body, err := c.sendGithubRequest(client, "GET", "/user", nil)
	user := &GithubUser{}
	err = json.Unmarshal(body, user)
	if err != nil {
		return nil, err
	}
	return user, nil
}

func (c *Config) CreatePipeline(client *http.Client, pipeline *PipelineData) error {
	user, err := c.GetUser(client)
	if err != nil {
		return err
	}
	pipeline.Login = "github|" + strconv.Itoa(user.ID)

	data, _ := json.Marshal(pipeline)
	_, err = c.sendAPIRequest(client, "POST", "/api/v1/pipelines", data)
	if err != nil {
		return err
	}
	return nil
}

func (c *Config) CreateBuild(client *http.Client, owner, repo string) error {
	user, err := c.GetUser(client)
	if err != nil {
		return err
	}
	login := "github|" + strconv.Itoa(user.ID)
	data := fmt.Sprintf(`{"author":"%s"}`, login)
	endpoint := fmt.Sprintf("/api/v1/pipelines/%s/%s/builds", owner, repo)
	_, err = c.sendAPIRequest(client, "POST", endpoint, []byte(data))
	if err != nil {
		return err
	}
	return nil
}

func (c *Config) validate() error {
	missing := []string{}
	if len(c.Host) == 0 {
		missing = append(missing, "host")
	}
	if len(c.Token) == 0 {
		missing = append(missing, "token")
	}
	if len(c.Secret) <= 0 {
		missing = append(missing, "secret")
	}
	if len(missing) > 0 {
		return fmt.Errorf("Missing configuration: [%s]", strings.Join(missing, ", "))
	}
	return nil
}

func (c *Config) sendAPIRequest(client *http.Client, method, endpoint string, data []byte) ([]byte, error) {
	url := c.Host + endpoint
	req, err := http.NewRequest(method, url, bytes.NewReader(data))
	if err != nil {
		return nil, err
	}

	jwtToken, err := createJWT(c.Token, c.Secret)
	if err != nil {
		return nil, err
	}
	auth := "Bearer " + jwtToken
	req.Header.Add("Authorization", auth)
	req.Header.Add("Accept", "application/json")
	req.Header.Add("Content-Type", "application/json")
	req.Header.Add("X-Custom-Event", scm.EventCLI)

	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}

	body, _ := ioutil.ReadAll(resp.Body)
	resp.Body.Close()

	if resp.StatusCode >= 400 && resp.StatusCode <= 500 {
		apiError := &Error{}
		err = json.Unmarshal(body, apiError)
		if err != nil {
			return nil, errors.New(resp.Status)
		}
		return nil, errors.New(apiError.Message)
	}

	return body, nil
}

func (c *Config) sendGithubRequest(client *http.Client, method, endpoint string, data []byte) ([]byte, error) {
	url := "https://api.github.com" + endpoint
	req, err := http.NewRequest(method, url, bytes.NewReader(data))
	if err != nil {
		return nil, err
	}

	authReqToken := "token " + c.Token
	req.Header.Add("Authorization", authReqToken)

	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}

	body, _ := ioutil.ReadAll(resp.Body)
	resp.Body.Close()

	if resp.StatusCode >= 400 && resp.StatusCode <= 500 {
		apiError := &Error{}
		err = json.Unmarshal(body, apiError)
		if err != nil {
			return nil, errors.New(resp.Status)
		}
		return nil, errors.New(apiError.Message)
	}

	return body, nil
}

func createJWT(accessToken string, secret string) (string, error) {
	if accessToken == "" {
		return "", errors.New("Access Token is empty")
	}

	token := jwt.New(jwt.SigningMethodHS256)
	token.Claims["identities"] = []map[string]string{
		{"access_token": accessToken},
	}

	s, _ := base64.URLEncoding.DecodeString(secret)
	jwtToken, err := token.SignedString(s)
	if err != nil {
		logrus.WithError(err).Errorln("Unable to Create JWT")
		return "", errors.New("Unable to Create JWT")
	}

	return jwtToken, nil
}
