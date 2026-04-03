#!/bin/bash

########## CONFIGURATIONS ##########
# Host on which qBittorrent runs
qbt_host="http://qbittorrent"
# Port -> the same port that is inside qBittorrent option -> Web UI -> Web User Interface
qbt_port="8080"
# Username to access to Web UI
qbt_username="chris_ede_"
# Password to access to Web UI
qbt_password="Ep172ewEGKKtxBF"

# If true (lowercase) the script will inject trackers inside private torrent too (not a good idea)
ignore_private=false

# If true (lowercase) the script will remove all existing trackers before inject the new one, this functionality will works only for public trackers
clean_existing_trackers=true

# Configure here your trackers list
declare -a live_trackers_list_urls=(
	"https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all_ip.txt"
	)
########## CONFIGURATIONS ##########

jq_executable="$(command -v jq)"
curl_executable="$(command -v curl)"
auto_tor_grab=0
test_in_progress=0
applytheforce=0
all_torrent=0
emptycategory=0

if [[ -z $jq_executable ]]; then
	echo -e "\n\e[0;91;1mFail on jq. Aborting.\n\e[0m"
	echo "You can find it here: https://stedolan.github.io/jq/"
	echo "Or you can install it with -> sudo apt install jq"
	exit 1
fi

if [[ -z $curl_executable ]]; then
	echo -e "\n\e[0;91;1mFail on curl. Aborting.\n\e[0m"
	echo "You can install it with -> sudo apt install curl"
	exit 2
fi

if [[ $qbt_host == "https://"* ]]; then
	curl_executable="${curl_executable} --insecure"
fi

version="v3.15"

########## FUNCTIONS ##########
generate_trackers_list () {
	for j in "${live_trackers_list_urls[@]}"; do
		trackers_list+=$($curl_executable -sS $j)
		trackers_list+=$'\n'
	done

	if [[ $? -ne 0 ]]; then
		echo "I can't download the list, I'll use a static one"
cat >"${trackers_list}" <<'EOL'

EOL
	fi
}

inject_trackers () {
	echo -ne "\e[0;36;1mInjecting... \e[0;36m"

	torrent_trackers=$(echo "$qbt_cookie" | $curl_executable --silent --fail --show-error \
				--cookie - \
				--request GET "${qbt_host}:${qbt_port}/api/v2/torrents/trackers?hash=${1}" | $jq_executable --raw-output '.[] | .url' | tail -n +4)

	remove_trackers $1 "${torrent_trackers//$'\n'/|}"

	if [[ $clean_existing_trackers == true ]]; then
		echo -e " \e[32mBut before a quick cleaning the existing trackers... "
		trackers_list=$(echo "$trackers_list" | sort | uniq)
	else
		trackers_list=$(echo "$trackers_list"$'\n'"$torrent_trackers" | sort | uniq)
	fi

	trackers_list=$(sed '/^$/d' <<< "$trackers_list")

	number_of_trackers_in_list=$(echo "$trackers_list" | wc -l)

	urls=${trackers_list//$'\n'/%0A%0A}

	echo "$qbt_cookie" | $curl_executable --silent --fail --show-error \
		-d "hash=${1}&urls=$urls" \
		--cookie - \
		--request POST "${qbt_host}:${qbt_port}/api/v2/torrents/addTrackers"

	echo -e "\e[32mdone, injected $number_of_trackers_in_list trackers!"
}

get_torrent_list () {
	get_cookie
	torrent_list=$(echo "$qbt_cookie" | $curl_executable --silent --fail --show-error \
		--cookie - \
		--request GET "${qbt_host}:${qbt_port}/api/v2/torrents/info")
}

url_encode() {
  local string="${1}"

  # Check if xxd is available
  if command -v xxd >/dev/null 2>&1; then
    # If xxd is available, use xxd for encoding
    printf '%s' "$string" | xxd -p | sed 's/\(..\)/%\1/g' | tr -d '\n'
  else
    # If jq is available, use jq for encoding
    jq -nr --arg s "$string" '$s|@uri'
  fi
}

get_cookie () {
	encoded_username=$(url_encode "$qbt_username")
	encoded_password=$(url_encode "$qbt_password")

	# If encoding fails, exit the function
	if [ $? -ne 0 ]; then
		echo "Error during URL encoding" >&2
		return 1
	fi

	qbt_cookie=$($curl_executable --silent --fail --show-error \
		--header "Referer: ${qbt_host}:${qbt_port}" \
		--cookie-jar - \
		--data "username=${encoded_username}&password=${encoded_password}" ${qbt_host}:${qbt_port}/api/v2/auth/login)
}

hash_check() {
	case $1 in
		( *[!0-9A-Fa-f]* | "" ) return 1 ;;
		( * )
			case ${#1} in
				( 32 | 40 ) return 0 ;;
				( * )       return 1 ;;
			esac
	esac
}

remove_trackers () {
	hash="$1"
	single_url="$2"
	echo "$qbt_cookie" | $curl_executable --silent --fail --show-error \
		-d "hash=${hash}&urls=${single_url}" \
		--cookie - \
		--request POST "${qbt_host}:${qbt_port}/api/v2/torrents/removeTrackers"
}

wait() {
	w=$1
	echo "I'll wait ${w}s to be sure ..."
	while [ $w -gt 0 ]; do
		echo -ne "$w\033[0K\r"
		sleep 1
		w=$((w-1))
	done
}
########## FUNCTIONS ##########

if [ -t 1 ] || [[ "$PWD" == *qbittorrent* ]] ; then
	if [[ ! $@ =~ ^\-.+ ]]; then
		echo "Arguments must be passed with - in front, like -n foo. Check instructions"
		echo ""
		$0 -h
		exit
	fi

	[ $# -eq 0 ] && $0 -h

	if [ $# -eq 1 ] && [ $1 == "-f" ]; then
		echo "Don't use only -f, you need to specify also the torrent!"
		exit
	fi

	while getopts ":acflhn:s:" opt; do
		case ${opt} in
			a ) # If used inject trackers to all torrent.
				all_torrent=1
				;;
			c ) # If used remove all the existing trackers before injecting the new ones.
				clean_existing_trackers=true
				;;
			f ) # If used force the injection also in private trackers.
				applytheforce=1
				;;
			l ) # Print the list of the torrent where you can inject trackers.
				get_torrent_list
				echo -e "\n\e[0;32;1mCurrent torrents:\e[0;32m"
				echo "$torrent_list" | $jq_executable --raw-output '.[] .name'
				exit
				;;
			n ) # Specify the name of the torrent example -n foo or -n "foo bar", multiple -n can be used.
				tor_arg_names+=("$OPTARG")
				;;
			s ) # Specify the category of the torrent example -s foo or -s "foo bar", multiple -s can be used. If -s is passed without arguments, the "default" categories will be used
				tor_categories+=("$OPTARG")
				;;
			: )
				echo "Invalid option: -${OPTARG} requires an argument" 1>&2
				exit 0
				;;
			\? )
				echo "Unknow option: -${OPTARG}" 1>&2
				exit 1
				;;
			h | * ) # Display help.
				echo "Usage:"
				echo "$0 -a	Inject trackers to all torrent in qBittorrent, this not require any extra information"
				echo "$0 -c	Clean all the existing trackers before the injection, this not require any extra information"
				echo "$0 -f	Force the injection of the trackers inside the private torrent too, this not require any extra information"
				echo "$0 -l	Print the list of the torrent where you can inject trackers, this not require any extra information"
				echo "$0 -n	Specify the torrent name or part of it, for example -n foo or -n 'foo bar'"
				echo "$0 -s	Specify the exact category name, for example -s foo or -s 'foo bar'. If -s is passed empty, \"\", the \"Uncategorized\" category will be used"
				echo "$0 -h	Display this help"
				echo ""
				echo "NOTE:"
				echo "It's possible to specify more than -n in one single command"
				echo "It's possible to specify more than -s in one single command"
				echo "Is also possible use -n foo -s bar to select specific name in specific category"
				echo "Just remember that if you set -a, is useless to add any extra arguments, like -n, but -f can always be used"
				exit 2
				;;
		esac
	done
	shift $((OPTIND -1))
else
	if [[ -n "${sonarr_download_id}" ]] || [[ -n "${radarr_download_id}" ]] || [[ -n "${lidarr_download_id}" ]] || [[ -n "${readarr_download_id}" ]]; then
		#wait 5
		if [[ -n "${sonarr_download_id}" ]]; then
			echo "Sonarr variable found -> $sonarr_download_id"
			hash=$(echo "$sonarr_download_id" | awk '{print tolower($0)}')
		fi

		if [[ -n "${radarr_download_id}" ]]; then
			echo "Radarr variable found -> $radarr_download_id"
			hash=$(echo "$radarr_download_id" | awk '{print tolower($0)}')
		fi

		if [[ -n "${lidarr_download_id}" ]]; then
			echo "Lidarr variable found -> $lidarr_download_id"
			hash=$(echo "$lidarr_download_id" | awk '{print tolower($0)}')
		fi

		if [[ -n "${readarr_download_id}" ]]; then
			echo "Readarr variable found -> $readarr_download_id"
			hash=$(echo "$readarr_download_id" | awk '{print tolower($0)}')
		fi

		hash_check "${hash}"
		if [[ $? -ne 0 ]]; then
			echo "No valid hash found for the torrent, I'll exit"
			exit 3
		fi
		auto_tor_grab=1
	fi

	if [[ $sonarr_eventtype == "Test" ]] || [[ $radarr_eventtype == "Test" ]] || [[ $lidarr_eventtype == "Test" ]] || [[ $readarr_eventtype == "Test" ]]; then
		echo "Test in progress..."
		test_in_progress=1
	fi
fi

for i in "${tor_arg_names[@]}"; do
	if [[ -z "${i// }" ]]; then
		echo "one or more argument for -n not valid, try again"
		exit
	fi
done

if [ $test_in_progress -eq 1 ]; then
	echo "Good-bye!"
elif [ $auto_tor_grab -eq 0 ]; then # manual run
	get_torrent_list

	if [ $all_torrent -eq 1 ]; then
		while IFS= read -r line; do
			torrent_name_array+=("$line")
		done < <(echo $torrent_list | $jq_executable --raw-output '.[] | .name')

		while IFS= read -r line; do
			torrent_hash_array+=("$line")
		done < <(echo $torrent_list | $jq_executable --raw-output '.[] | .hash')
	else
		if [[ ${#tor_arg_names[@]} -gt 0 && ${#tor_categories[@]} -gt 0 ]]; then
			for name in "${tor_arg_names[@]}"; do
				for category in "${tor_categories[@]}"; do
					torrent_name_list=$(echo "$torrent_list" | $jq_executable --arg category "$category" --arg name "$name" --raw-output '.[] | select(.category | ascii_downcase == ($category | ascii_downcase)) | select(.name | ascii_downcase | contains($name | ascii_downcase)) | .name')

					if [ -n "$torrent_name_list" ]; then # not empty
						torrent_name_check=1

						if [[ $category == "" ]]; then
							echo -e "\n\e[0;32;1mFor the name ### $name ### in category ### Uncategorized ###\e[0;32m"
						else
							echo -e "\n\e[0;32;1mFor the name ### $name ### in category ### $category ###\e[0;32m"
						fi

						echo -e "\e[0;32;1mI found the following torrent(s):\e[0;32m"
						echo "$torrent_name_list"
					else
						torrent_name_check=0
					fi

					if [ $torrent_name_check -eq 0 ]; then
						if [[ $category == "" ]]; then
							echo -e "\n\e[0;31;1mI didn't find a torrent with name ### $name ### in category ### Uncategorized ###\e[0m"
						else
							echo -e "\n\e[0;31;1mI didn't find a torrent with name ### $name ### in category ### $category ###\e[0m"
						fi

						shift
						continue
					else
						while read -r single_found; do
							torrent_name_array+=("$single_found")
							hash=$(echo "$torrent_list" | $jq_executable --arg single "$single_found" --raw-output '.[] | select(.name == "\($single)") | .hash')
							torrent_hash_array+=("$hash")
						done <<< "$torrent_name_list"
					fi
				done
			done
		elif [[ ${#tor_arg_names[@]} -gt 0 ]]; then
			for name in "${tor_arg_names[@]}"; do
				torrent_name_list=$(echo "$torrent_list" | $jq_executable --arg name "$name" --raw-output '.[] | select(.name | ascii_downcase | contains($name | ascii_downcase)) | .name') #possible fix for ONIGURUMA regex libary

				if [ -n "$torrent_name_list" ]; then # not empty
					torrent_name_check=1
					echo -e "\n\e[0;32;1mFor the name ### $name ###\e[0;32m"
					echo -e "\e[0;32;1mI found the following torrent(s):\e[0;32m"
					echo "$torrent_name_list"
				else
					torrent_name_check=0
				fi

				if [ $torrent_name_check -eq 0 ]; then
					echo -e "\n\e[0;31;1mI didn't find a torrent with this part of the text: \e[21m$name\e[0m"
					shift
					continue
				else
					while read -r single_found; do
						torrent_name_array+=("$single_found")
						hash=$(echo "$torrent_list" | $jq_executable --arg single "$single_found" --raw-output '.[] | select(.name == "\($single)") | .hash')
						torrent_hash_array+=("$hash")
					done <<< "$torrent_name_list"
				fi
			done
		else
			for category in "${tor_categories[@]}"; do
				torrent_name_list=$(echo "$torrent_list" | $jq_executable --arg category "$category" --raw-output '.[] | select(.category | ascii_downcase == ($category | ascii_downcase)) | .name')

				if [ -n "$torrent_name_list" ]; then # not empty
					torrent_name_check=1

					if [[ $category == "" ]]; then
						echo -e "\n\e[0;32;1mFor category ### Uncategorized ###\e[0;32m"
					else
						echo -e "\n\e[0;32;1mFor category ### $category ###\e[0;32m"
					fi

					echo -e "\e[0;32;1mI found the following torrent(s):\e[0;32m"
					echo "$torrent_name_list"
				else
					torrent_name_check=0
				fi

				if [ $torrent_name_check -eq 0 ]; then
					echo -e "\n\e[0;31;1mI didn't find a torrent in the category: \e[21m$category\e[0m"
					shift
					continue
				else
					while read -r single_found; do
						torrent_name_array+=("$single_found")
						hash=$(echo "$torrent_list" | $jq_executable --arg single "$single_found" --raw-output '.[] | select(.name == "\($single)") | .hash')
						torrent_hash_array+=("$hash")
					done <<< "$torrent_name_list"
				fi
			done
		fi
	fi

	if [ ${#torrent_name_array[@]} -gt 0 ]; then
		echo ""
		for i in "${!torrent_name_array[@]}"; do
			echo -ne "\n\e[0;1;4;32mFor the Torrent: \e[0;4;32m"
			echo "${torrent_name_array[$i]}"

			if [[ $ignore_private == true ]] || [ $applytheforce -eq 1 ]; then # Inject anyway the trackers inside any torrent
				if [ $applytheforce -eq 1 ]; then
					echo -e "\e[0m\e[33mForce mode is active, I'll inject trackers anyway\e[0m"
				else
					echo -e "\e[0m\e[33mignore_private set to true, I'll inject trackers anyway\e[0m"
				fi
				generate_trackers_list
				inject_trackers ${torrent_hash_array[$i]}
			else
				private_check=$(echo "$qbt_cookie" | $curl_executable --silent --fail --show-error --cookie - --request GET "${qbt_host}:${qbt_port}/api/v2/torrents/properties?hash=$(echo "$torrent_list" | $jq_executable --raw-output --arg tosearch "${torrent_name_array[$i]}" '.[] | select(.name == "\($tosearch)") | .hash')" | $jq_executable --raw-output '.is_private')

				if [[ $private_check == true ]]; then
					private_tracker_name=$(echo "$qbt_cookie" | $curl_executable --silent --fail --show-error --cookie - --request GET "${qbt_host}:${qbt_port}/api/v2/torrents/trackers?hash=$(echo "$torrent_list" | $jq_executable --raw-output --arg tosearch "${torrent_name_array[$i]}" '.[] | select(.name == "\($tosearch)") | .hash')" | $jq_executable --raw-output '.[3] | .url' | sed -e 's/[^/]*\/\/\([^@]*@\)\?\([^:/]*\).*/\2/')
					echo -e "\e[31m< Private tracker found \e[0m\e[33m-> $private_tracker_name <- \e[0m\e[31mI'll not add any extra tracker >\e[0m"
				else
					echo -e "\e[0m\e[33mThe torrent is not private, I'll inject trackers on it\e[0m"
					generate_trackers_list
					inject_trackers ${torrent_hash_array[$i]}
				fi
			fi
		done
	else
		echo "No torrents found, exiting"
	fi
else # auto_tor_grab active, so some *Arr
	wait 5
	get_torrent_list

	private_check=$(echo "$qbt_cookie" | $curl_executable --silent --fail --show-error --cookie - --request GET "${qbt_host}:${qbt_port}/api/v2/torrents/properties?hash=$hash" | $jq_executable --raw-output '.is_private')

	if [[ $private_check == true ]]; then
		private_tracker_name=$(echo "$qbt_cookie" | $curl_executable --silent --fail --show-error --cookie - --request GET "${qbt_host}:${qbt_port}/api/v2/torrents/trackers?hash=$hash" | $jq_executable --raw-output '.[3] | .url' | sed -e 's/[^/]*\/\/\([^@]*@\)\?\([^:/]*\).*/\2/')
		echo -e "\e[31m< Private tracker found \e[0m\e[33m-> $private_tracker_name <- \e[0m\e[31mI'll not add any extra tracker >\e[0m"
	else
		echo -e "\e[0m\e[33mThe torrent is not private, I'll inject trackers on it\e[0m"
		generate_trackers_list
		inject_trackers $hash
	fi
fi