package main

// TODO:
//   Cleanup image info (spaces to separate from "Served from" message
//   Add verbose template index.html.tmpl.verbose.tmpl to handle extra info

import (
    "flag"
    "fmt"
    "html/template"
    "log"
    "net"
    "net/http"
    "os"
    "strings"
    "io/ioutil"
    "bytes"   // for bytes.Buffer
    "time"    // Used for Sleep
    // "strconv" // Used to get integer from string
    // "encoding/json"
)

const (
    // Courtesy of "telnet mapascii.me"
    MAP_ASCII_ART      = "static/img/mapascii.txt"

    escape             = "\x1b"
    colour_me_black    = escape + "[0;30m"
    colour_me_red      = escape + "[0;31m"
    colour_me_green    = escape + "[0;32m"
    colour_me_yellow   = escape + "[0;33m"
    colour_me_blue     = escape + "[0;34m"
    colour_me_magenta  = escape + "[0;35m"
    colour_me_cyan     = escape + "[0;36m"
    colour_me_white    = escape + "[0;37m"

    colour_me_normal   = escape + "[0;0m"
)

var (
    // Used for metrics_demoapp_age:
    start_time  int64 =  0

    // -- defaults: can be overridden by cli ------------
    // -- defaults: to be overridden by env/cli/cm ------
    message            = ""

    /*
       NODE_NAME must be provided - the intention is to pick it up from the Kubernetes downwardAPI:
       e.g.
          # Get NODE_NAME via downwardAPI
          env:
          - name: NODE_NAME
            valueFrom:
              fieldRef:
                fieldPath: spec.nodeName
    */
    NODE_NAME          = os.Getenv("NODE_NAME")

    IMAGE_NAME_VERSION = os.Getenv("IMAGE_NAME_VERSION")
    IMAGE_VERSION      = os.Getenv("IMAGE_VERSION")
    DATE_VERSION       = os.Getenv("DATE_VERSION")
    logo_base_path     = os.Getenv("PICTURE_PATH_BASE")
    logo_path          = logo_base_path + ".txt"

    colour_text=colour_me_white
    text_colour    = os.Getenv("PICTURE_COLOUR")

    listenAddr    string = ":80"
    testModeUrl   string = ""
    verbose    bool
    headers    bool

    livenessSecs int
    readinessSecs int

    dieafter int
    die  bool
    liveanddie bool
    readyanddie bool

    version  bool

    // Prometheus metrics:
    metrics_demoapp_requests       = 0
    metrics_demoapp_response_bytes = 0
    metrics_demoapp_age            = int64(0)
)

type (
    Content struct {
        Title       string
        Hostname    string
        Hosttype    string
        Message     string
        PNG         string
        UsingImage  string
        NetworkInfo string
        FormattedReq   string
    }
)

// Get preferred outbound ip of this machine
func GetOutboundIP() net.IP {
    conn, err := net.Dial("udp", "8.8.8.8:80")
    if err != nil {
        log.Fatal(err)
    }
    defer conn.Close()

    localAddr := conn.LocalAddr().(*net.UDPAddr)

    return localAddr.IP
}

// -----------------------------------
// func: init
//
// Read command-line arguments:
//
func init() {
    /* We would normally parse command-line arguments like this
       but we cannot pass arguments to flag.parse()
       so we cannot use ENV vars as something to be parsed as cli args:
    flag.StringVar(&listenAddr, "listen", listenAddr, "listen address")
    */
}

// -----------------------------------
// func: loadTemplate
//
// load template file and substitute variables
//
func loadTemplate(filename string) (*template.Template, error) {
    return template.ParseFiles(filename)
}

// -----------------------------------
// func: CaseInsensitiveContains
//
// Do case insensitive match - of substr in s
//
func CaseInsensitiveContains(s, substr string) bool {
    s, substr = strings.ToUpper(s), strings.ToUpper(substr)
    return strings.Contains(s, substr)
}

// -----------------------------------
// func: route_echoRequest
//
// generates ascii representation of a request
//
// From: https://medium.com/doing-things-right/pretty-printing-http-requests-in-golang-a918d5aaa000
//
func route_echoRequest(w http.ResponseWriter, r *http.Request) {
    respBody := formatRequest(r)
    fmt.Fprintf(w, "%s", respBody)

    metrics_demoapp_requests++
    metrics_demoapp_response_bytes+=len(respBody)
    return
}

// -----------------------------------
// func: formatRequest
//
// generates ascii representation of a request
//
// From: https://medium.com/doing-things-right/pretty-printing-http-requests-in-golang-a918d5aaa000
//
func formatRequest(r *http.Request) string {
    // Create return string
    var request []string

    // Add the request string
    url := fmt.Sprintf("%v %v %v", r.Method, r.URL, r.Proto)
    request = append(request, url)

    // Add the host
    request = append(request, fmt.Sprintf("Host: %v", r.Host))

    // Loop through headers
    for name, headers := range r.Header {
        name = strings.ToLower(name)
        for _, h := range headers {
            request = append(request, fmt.Sprintf("%v: %v", name, h))
        }
    }

    // If this is a POST, add post data
    if r.Method == "POST" {
        r.ParseForm()
        request = append(request, "\n")
        request = append(request, r.Form.Encode())
    }

    // Return the request as a string
    return strings.Join(request, "\n")
}

// -----------------------------------
// func: route_statusCodeTest
//
// Example handler - sets status code
//
func route_statusCodeTest(w http.ResponseWriter, req *http.Request) {
    //m := map[string]string{ "foo": "bar", }
    //w.Header().Add("Content-Type", "application/json")
    //num := http.StatusCreated
    num := http.StatusInternalServerError

    w.WriteHeader( num )

    //_ = json.NewEncoder(w).Encode(m)
    respBody := fmt.Sprintf("\nWriting status code <%d>\n", num)
    fmt.Fprintf(w, respBody)
    metrics_demoapp_requests++
    metrics_demoapp_response_bytes+=len(respBody)
}

// -----------------------------------
// func: route_metrics
//
// Prometheus Metrics handler
//
func route_metrics(w http.ResponseWriter, r *http.Request) {
    currentTime := time.Now()
    now_sec     := currentTime.Unix()
    metrics_demoapp_age = now_sec - start_time

    templateStr := `# HELP demoapp_age The age in seconds of this instance
# TYPE demoapp_age counter
demoapp_age{image="%s"} %v
# HELP demoapp_requests The total number of processed events
# TYPE demoapp_requests counter
demoapp_requests{image="%s"} %d
# HELP demoapp_response_bytes The total number of processed events
# TYPE demoapp_response_bytes counter
demoapp_response_bytes{image="%s"} %d
`
    respBody := fmt.Sprintf(templateStr,
        IMAGE_NAME_VERSION, metrics_demoapp_age,
        IMAGE_NAME_VERSION, metrics_demoapp_requests,
        IMAGE_NAME_VERSION, metrics_demoapp_response_bytes)
    // don't count metrics requests: metrics_demoapp_requests++
    // don't count metrics requests: metrics_demoapp_response_bytes+=len(respBody)
    fmt.Fprintf(w, respBody)
}

// -----------------------------------
// func: route_index
//
// Main index handler - handles different requests
//
func route_index(w http.ResponseWriter, r *http.Request) {
    //currentTime := time.Now()
    //log.Printf("%s: Request from '%s' (%s)\n", currentTime.String(), r.Header.Get("X-Forwarded-For"), r.URL.Path)
    log.Printf(": Request from '%s' (%s)\n", r.Header.Get("X-Forwarded-For"), r.URL.Path)

    switch text_colour {
        case "black":   colour_text=colour_me_black
        case "red":     colour_text=colour_me_red
        case "green":   colour_text=colour_me_green
        case "yellow":  colour_text=colour_me_yellow
        case "blue":    colour_text=colour_me_blue
        case "magenta": colour_text=colour_me_magenta
        case "cyan":    colour_text=colour_me_cyan
        case "white":   colour_text=colour_me_white
    }

    //if (dieafter > 0) {
    //    if now > started +dieafter {
    //        log.Fatal("Dying once delay")
    //        os.Exit(4)
    //   }
    //}

    if readyanddie {
        log.Fatal("Dying once ready")
        os.Exit(3)
    }

    // Get user-agent: if text-browser, e.g. wget/curl/httpie/lynx/elinks return ascii-text image:
    //

    userAgent        := r.Header.Get("User-Agent")
    from             := r.RemoteAddr
    fwd              := r.Header.Get("X-Forwarded-For")
    formattedRequest := formatRequest(r)
    url              := r.URL.Path

    respBody, byteContent, contentType := getResponseBody( url, userAgent, formattedRequest, from, fwd)
    if contentType != "" {
         // w.Header().Set("Content-Type", "text/txt")
         w.Header().Set( "Content-Type", contentType )
         w.Write([]byte( byteContent ))
    }

    metrics_demoapp_requests++
    metrics_demoapp_response_bytes+=len(respBody)
    fmt.Fprintf(w, respBody)
}

// -----------------------------------
// func: getResponseBody
//
// Main index handler - handles different requests
//
func getResponseBody(url string, userAgent string, formattedReq string, from string, fwd string) (string, []byte, string) {

    byteContent := []byte("")

    contentType  := ""

    hostName, err := os.Hostname()
    if err != nil {
        hostName = "unknown"
    }

    // Enable/disable headers:
    if url == "/headers"    { headers = true }
    if url == "/no-headers" { headers = false }

    multilineOP := (url != "/1line") && (url != "/1l") && (url != "/1")

    networkInfo  := ""
    if verbose && multilineOP {
        networkInfo = getNetworkInfo()
    }
    if !headers {
        formattedReq   = ""
    }

    hostType      := ""
    imageInfo     := ""
    htmlPageTitle := ""
    msg           := ""
    if message != "" { msg = "'" + message + "'" }

    if IMAGE_NAME_VERSION == "" {
        hostType = "host"
        htmlPageTitle = msg
    } else {
        hostType = "pod"
        imageInfo = "[" + IMAGE_NAME_VERSION + "]"
        htmlPageTitle = msg + " " + imageInfo
    }

    if CaseInsensitiveContains(userAgent, "wget") ||
       CaseInsensitiveContains(userAgent, "curl") ||
       CaseInsensitiveContains(userAgent, "http") ||
       CaseInsensitiveContains(userAgent, "links") ||
       CaseInsensitiveContains(userAgent, "lynx") {
        contentType = "text/txt"

        logo_path  =  logo_base_path + ".txt"

        //fmt.Fprintf(w, "%s", formattedReq)
        //?
        retStr := formattedReq
        //retStr := fmt.Sprintf("%s", formattedReq)

        if url == "/map" || url == "/MAP" {
            byteContent, _ = ioutil.ReadFile( MAP_ASCII_ART )
        } else {
            fmt.Printf("DEBUG: logo_path='%s'\n", logo_path)
            if multilineOP {
                byteContent, _ = ioutil.ReadFile( logo_path )
            }
        }

        myIP := GetOutboundIP()
        d    := " "
        if multilineOP {
            d = "\n"
        }

        if fwd != "" { fwd=" [" + fwd + "]" }

        // MESSAGE
        NODE_INFO:=""
        if (NODE_NAME != "" && hostType == "pod") {
            NODE_INFO="[host " + NODE_NAME + "] "
        }

        p1 := fmt.Sprintf("%s%s %s%s@%s%s " + "%simage%s%s " + "Request from %s%s" + "%s%s" + "%s",
            NODE_INFO, hostType, colour_me_yellow, hostName, myIP, colour_me_normal,
            colour_text, colour_me_normal, imageInfo,
            from, fwd,
            networkInfo, d,
            msg)

        retStr = retStr + p1
        if !multilineOP { retStr += "\n"; }

        //fmt.Printf("byteContent='%s'\n", string(byteContent) )
        return retStr, byteContent, contentType
    }

    logo_path  =  logo_base_path + ".png"

    templateFile := "templates/index.html.tmpl"

    template, err := loadTemplate(templateFile)
    if err != nil {
        log.Printf("error loading template from %s: %s\n", templateFile, err)
        return "", []byte(""), contentType
    }

    cnt := &Content{
        Title:        htmlPageTitle,
        Hosttype:     hostType,
        Hostname:     hostName,
        Message:      message,
        PNG:          logo_path,
        UsingImage:   imageInfo,
        NetworkInfo:  networkInfo,
        FormattedReq: formattedReq,
    }

    // apply Context values to template
    var tpl bytes.Buffer
    template.Execute(&tpl, cnt)

    return tpl.String(), byteContent, contentType
}

func getNetworkInfo() string {
    ret := "Network interfaces:\n"

    ifaces, _ := net.Interfaces()
    // handle err
    for _, i := range ifaces {
        addrs, _ := i.Addrs()
        // handle err
        for _, addr := range addrs {
            var ip net.IP
            switch v := addr.(type) {
                case *net.IPNet:
                    ip = v.IP
                case *net.IPAddr:
                    ip = v.IP
            }
            // process IP address
            //ret = fmt.Sprintf("%sip %s\n", ret, ip.String())
            ret = fmt.Sprintf("%sip %s", ret, ip.String())
        }
    }
    //ret = fmt.Sprintf("%slistening on port %s\n", ret, listenAddr)
    ret = fmt.Sprintf("%slistening on port %s", ret, listenAddr)

    return ret
}

// -----------------------------------
// func: route_ping
//
// Ping handler - echos back remote address
//
func route_ping(w http.ResponseWriter, r *http.Request) {
    respBody := fmt.Sprintf("route_ping: hello %s\n", r.RemoteAddr)

    metrics_demoapp_requests++
    metrics_demoapp_response_bytes+=len(respBody)
    w.Write([]byte(respBody))
}

func route_showVersion(w http.ResponseWriter, r *http.Request) {
    respBody := fmt.Sprintf("version: %s [%s]\n", DATE_VERSION, IMAGE_NAME_VERSION)

    metrics_demoapp_requests++
    metrics_demoapp_response_bytes+=len(respBody)
    w.Write([]byte(respBody))
}

// -----------------------------------
// func: main
//
//
//
func main() {
    start_time = time.Now().Unix()

    f := flag.NewFlagSet("flag", flag.ExitOnError)

    f.StringVar(&listenAddr, "listen", listenAddr, "listen address")
    f.StringVar(&listenAddr, "l",      listenAddr, "listen address")
    f.BoolVar(&die,         "die", false,   "die before live (false)")
    f.IntVar(&dieafter,     "dieafter", -1, "die after (NEVER)")

    f.BoolVar(&liveanddie,   "Liveanddie",false,   "die once live (false)")
    f.IntVar(&livenessSecs,  "Live",   0,   "liveness delay (0 sec)")
    f.IntVar(&livenessSecs,  "L",      0,   "liveness delay (0 sec)")

    f.BoolVar(&readyanddie,  "Readyanddie",false,   "die once ready (false)")
    f.IntVar(&readinessSecs, "Ready",  0,   "readiness delay (0 sec)")
    f.IntVar(&readinessSecs, "R",      0,   "readiness delay (0 sec)")

    //f.StringVar(&IMAGE_NAME_VERSION, "image", IMAGE_NAME_VERSION, "image")
    //f.StringVar(&IMAGE_NAME_VERSION, "i", IMAGE_NAME_VERSION, "image")

    f.StringVar(&message,            "message", "", "message")

    f.BoolVar(&version,      "version", false,  "Show version and exit")

    f.StringVar(&testModeUrl, "testmode", "", "testmode (url)")
    //f.StringVar(&testModeUrl, "t",        testModeUrl, "testmode (url)")

    f.BoolVar(&verbose,      "verbose",false,   "verbose (false)")
    f.BoolVar(&verbose,      "v",      false,   "verbose (false)")
    f.BoolVar(&headers,      "headers",false,   "show headers (false)")
    f.BoolVar(&headers,      "h",      false,   "show headers (false)")

    // fmt.Printf("HELLO WORLD\n"); os.Exit(0)

    // visitor := func(a *flag.Flag) { fmt.Println(">", a.Name, "value=", a.Value); }
    // fmt.Println("Visit()"); f.Visit(visitor) fmt.Println("VisitAll()")
    // f.VisitAll(visitor); fmt.Println("VisitAll()")

    if os.Getenv("CLI_ARGS") != "" {
        cli_args := os.Getenv("CLI_ARGS")
        a_cli_args := strings.Split(cli_args, " ")

        f.Parse(a_cli_args)
    } else {
        f.Parse(os.Args[1:])
    }

    // allow :<port> or just <port> argument:
    //fmt.Println(listenAddr)
    if !strings.Contains(listenAddr, ":") {
        listenAddr = ":" + listenAddr
        //fmt.Println("==> :"+listenAddr)
    }
    //fmt.Println(listenAddr)

    //fmt.Printf("listenAddr='" + listenAddr + "'\n")
    if testModeUrl != "" {
        //logo_base_path =
        //fmt.Printf("testModeUrl='" + testModeUrl + "'\n")
        logo_base_path = "static/img/kubernetes_blue"

        userAgent := "curl"
        from      := "<from-addr>"
        fwd       := "<Xfwd-addr>"
        respBody, byteContent, contentType := getResponseBody(testModeUrl, userAgent, "", from, fwd)
        if contentType == "text/txt" {
           fmt.Printf("Content-Type: text/txt\n\n")
        }
        // MEESSED UP WITH "MISSING" strings: fmt.Printf(byteContent.String())
        //fmt.Printf("byteContent='%s'\n", string(byteContent) )
        fmt.Printf("%s\n", string(byteContent) )
        fmt.Printf( respBody )
        os.Exit(0)
    }

    // fmt.Println("Visit() after Parse()"); f.Visit(visitor);
    // fmt.Println("VisitAll() after Parse()") f.VisitAll(visitor)

    if verbose || version {
        log.Printf("%s Version: %s\n", os.Args[0], DATE_VERSION)

        if version {
            os.Exit(0)
        }
        log.Printf("%s\n", strings.Join(os.Args, " "))
    }

    if die {
        log.Fatal("Dying at beginning")
        os.Exit(1)
    }
    if (livenessSecs > 0) {
        //  Artificially sleep to simulate container initialization:
        delay := time.Duration(livenessSecs) * 1000 * time.Millisecond
        log.Printf("[liveness] Sleeping <%d> secs\n", livenessSecs)
        time.Sleep(delay)
    }
    if liveanddie {
        log.Fatal("Dying once live")
        os.Exit(2)
    }

    // ---- setup routes: -------------------------------------------------

    // ---- act as static web server on /static/*
    if testModeUrl == "" {
        mux := http.NewServeMux()

        mux.Handle("/static/", http.StripPrefix("/static/", http.FileServer(http.Dir("./static"))))

        mux.HandleFunc("/", route_index)
        mux.HandleFunc("/test", route_statusCodeTest)

        mux.HandleFunc("/version", route_showVersion)

        mux.HandleFunc("/echo", route_echoRequest)
        mux.HandleFunc("/ECHO", route_echoRequest)

        mux.HandleFunc("/ping", route_ping)
        mux.HandleFunc("/PING", route_ping)

        mux.HandleFunc("/MAP", route_index)
        mux.HandleFunc("/map", route_index)

        mux.HandleFunc("/metrics", route_metrics)

        if (readinessSecs > 0) {
            //  Artificially sleep to simulate application initialization:
            delay := time.Duration(readinessSecs) * 1000 * time.Millisecond
            log.Printf("[readiness] Sleeping <%d> secs\n", readinessSecs)
            time.Sleep(delay)
        }
        if readyanddie {
            log.Fatal("Dying once ready")
            os.Exit(3)
        }

        if verbose {
            log.Printf("Default ascii art <%s>\n", logo_path)
        }

        hostname, err := os.Hostname()
        if err != nil { hostname="HOST"; }

        //currentTime := time.Now()
        //log.Printf("%s [%s]: Now listening on port %s\n", currentTime.String(), hostname, listenAddr)
        if NODE_NAME == "" {
            log.Printf("[%s]: Now listening on port %s\n", hostname, listenAddr)
        } else {
            log.Printf("[host:%s cont:%s]: Now listening on port %s\n", NODE_NAME, hostname, listenAddr)
        }
        if err := http.ListenAndServe(listenAddr, mux); err != nil {
            log.Fatalf("error serving: %s", err)
        }
    }

    // started=now
}

